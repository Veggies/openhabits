import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:isolate';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:sqlite3/sqlite3.dart';

import '../sync_store.dart';

class User {
  final String id;
  final String username;
  final String? email;
  final bool isOwner;

  const User(this.id, this.username, this.email, this.isOwner);

  Map<String, Object?> toJson() => {
    'id': id,
    'username': username,
    'email': email,
    'isOwner': isOwner,
  };
}

class AuthException implements Exception {
  final String message;
  const AuthException(this.message);

  @override
  String toString() => message;
}

/// Someone tried to set up a server that already has an owner.
class SetupDoneException extends AuthException {
  const SetupDoneException()
    : super("This server's already set up, so just sign in.");
}

/// Accounts, sessions and short-lived one-time codes.
///
/// Passwords are stored as salted PBKDF2-SHA256 hashes. Session tokens and
/// codes are random and only their SHA-256 hashes are stored, so a leaked
/// database doesn't leak working credentials.
class AuthStore {
  final Database _db;
  final SyncStore _sync;
  final DateTime Function() _clock;
  final _random = Random.secure();

  /// One-time codes: hash → (user, expiry). Kept in memory; they last
  /// minutes, so losing them on restart is harmless.
  final _codes = <String, ({String userId, DateTime expires})>{};

  /// Failed sign-ins and code redemptions, for rate limiting. Keyed by
  /// client and username (so one person guessing can't lock everyone else
  /// out), and by client alone (so trying many usernames is limited too).
  final _failures = <String, ({int count, DateTime until, DateTime last})>{};

  /// Password checks waiting for, or running in, a background isolate.
  int _checksInFlight = 0;
  final _checkQueue = Queue<Completer<void>>();

  static const passwordIterations = 120000;
  static const codeLifetime = Duration(minutes: 10);

  /// Sessions not used for this long stop working.
  static const sessionLifetime = Duration(days: 90);

  /// Failures are forgotten after this long without another one.
  static const failureMemory = Duration(hours: 1);

  /// Password checks run in the background, at most this many at once, so
  /// sign-in attempts can't stall syncing. Beyond [maxQueuedChecks]
  /// waiting, new attempts are turned away.
  static const maxConcurrentChecks = 2;
  static const maxQueuedChecks = 16;

  AuthStore(this._sync, {DateTime Function()? clock})
    : _db = _sync.db,
      _clock = clock ?? DateTime.now {
    _db.execute('''
      CREATE TABLE IF NOT EXISTS users (
        id TEXT PRIMARY KEY,
        username TEXT NOT NULL UNIQUE COLLATE NOCASE,
        email TEXT COLLATE NOCASE,
        password_hash TEXT,
        is_owner INTEGER NOT NULL DEFAULT 0,
        created_at TEXT NOT NULL
      );
      CREATE TABLE IF NOT EXISTS sessions (
        token_hash TEXT PRIMARY KEY,
        user_id TEXT NOT NULL,
        device TEXT NOT NULL,
        created_at TEXT NOT NULL,
        last_seen TEXT NOT NULL
      );
      -- One private calendar link per person. Kept as-is (not hashed) so the
      -- app can show the link again; it only grants reading the calendar.
      CREATE TABLE IF NOT EXISTS calendar_links (
        user_id TEXT PRIMARY KEY,
        token TEXT NOT NULL UNIQUE
      );
    ''');
  }

  bool get hasUsers => _db.select('SELECT 1 FROM users LIMIT 1').isNotEmpty;

  User? get owner => _userWhere('is_owner = 1');

  User? userById(String id) => _userWhere('id = ?', [id]);

  User? userByName(String username) => _userWhere('username = ?', [username]);

  User? userByEmail(String email) => _userWhere('email = ?', [email]);

  List<User> get users => [
    for (final r in _db.select('SELECT * FROM users ORDER BY created_at'))
      _toUser(r),
  ];

  User? _userWhere(String where, [List<Object?> args = const []]) {
    final rows = _db.select('SELECT * FROM users WHERE $where LIMIT 1', args);
    return rows.isEmpty ? null : _toUser(rows.first);
  }

  User _toUser(Row r) => User(
    r['id'] as String,
    r['username'] as String,
    r['email'] as String?,
    r['is_owner'] == 1,
  );

  /// Creates an account. The first account becomes the owner and inherits
  /// any data stored before accounts existed.
  User createUser(String username, {String? password, String? email}) {
    final name = username.trim();
    if (!RegExp(r'^[A-Za-z0-9._@-]{2,64}$').hasMatch(name)) {
      throw const AuthException(
        'Usernames can be 2 to 64 characters long, using letters, numbers, dots, dashes or underscores.',
      );
    }
    if (password != null && password.length < 8) {
      throw const AuthException('Passwords need at least 8 characters.');
    }
    if (userByName(name) != null) {
      throw AuthException('"$name" is already taken.');
    }
    final isOwner = !hasUsers;
    final id = _token(12);
    _db.execute(
      'INSERT INTO users (id, username, email, password_hash, is_owner, created_at) '
      'VALUES (?, ?, ?, ?, ?, ?)',
      [
        id,
        name,
        email?.trim().isEmpty ?? true ? null : email!.trim(),
        password == null ? null : hashPassword(password),
        isOwner ? 1 : 0,
        _clock().toUtc().toIso8601String(),
      ],
    );
    if (isOwner) _sync.adoptUnownedData(id);
    return userById(id)!;
  }

  /// Creates the first account, the owner, but only if there are no
  /// accounts yet. The check and the insert happen with nothing in between,
  /// so two people setting up at once can't both succeed.
  User createOwner(String username, {required String password, String? email}) {
    if (hasUsers) throw const SetupDoneException();
    return createUser(username, password: password, email: email);
  }

  void deleteUser(String id) {
    final user = userById(id);
    if (user == null) return;
    if (user.isOwner) throw const AuthException("The owner can't be removed.");
    _db.execute('DELETE FROM sessions WHERE user_id = ?', [id]);
    _db.execute('DELETE FROM calendar_links WHERE user_id = ?', [id]);
    _db.execute('DELETE FROM users WHERE id = ?', [id]);
    _sync.deleteUserData(id);
  }

  void setPassword(String userId, String password) {
    if (password.length < 8) {
      throw const AuthException('Passwords need at least 8 characters.');
    }
    _db.execute('UPDATE users SET password_hash = ? WHERE id = ?', [
      hashPassword(password),
      userId,
    ]);
  }

  void setEmail(String userId, String? email) => _db.execute(
    'UPDATE users SET email = ? WHERE id = ?',
    [email?.trim().isEmpty ?? true ? null : email!.trim(), userId],
  );

  /// Checks a username and password. [client] identifies the caller (e.g.
  /// its IP) for rate limiting: after 5 wrong passwords for one username,
  /// or 20 across all usernames, that client waits a growing delay.
  ///
  /// The password check is slow on purpose, so it runs in the background
  /// and doesn't hold up other requests.
  Future<User> signIn(
    String username,
    String password, {
    String client = '',
  }) async {
    final name = username.trim().toLowerCase();
    final keys = ['$client|$name', '$client|*'];
    _checkLockout(keys[0], 5);
    _checkLockout(keys[1], 20);
    // Count the attempt before checking, so a burst of attempts sent at
    // once can't all slip in before the first one fails.
    _recordFailure(keys[0], 5);
    _recordFailure(keys[1], 20);
    final rows = _db.select('SELECT * FROM users WHERE username = ?', [
      username.trim(),
    ]);
    final hash = rows.isEmpty ? null : rows.first['password_hash'] as String?;
    // Verify even for unknown users so response time doesn't reveal them.
    final ok = await _verifyInBackground(password, hash ?? _dummyHash);
    if (rows.isEmpty || hash == null || !ok) {
      throw const AuthException("That username or password isn't right.");
    }
    _failures.remove(keys[0]);
    _forgiveOne(keys[1]);
    return _toUser(rows.first);
  }

  void _checkLockout(String key, int allowed) {
    final now = _clock();
    final f = _failures[key];
    if (f == null) return;
    if (now.difference(f.last) > failureMemory && now.isAfter(f.until)) {
      _failures.remove(key);
      return;
    }
    if (f.count >= allowed && now.isBefore(f.until)) {
      final wait = f.until.difference(now).inSeconds + 1;
      throw AuthException(
        "That's too many tries for now. Wait $wait seconds and try again.",
      );
    }
  }

  void _recordFailure(String key, int allowed) {
    final now = _clock();
    if (_failures.length > 10000) {
      _failures.removeWhere(
        (_, f) =>
            now.difference(f.last) > failureMemory && now.isAfter(f.until),
      );
    }
    final count = (_failures[key]?.count ?? 0) + 1;
    final lockout = Duration(
      seconds: count < allowed ? 0 : 30 * (1 << min(count - allowed, 6)),
    );
    _failures[key] = (count: count, until: now.add(lockout), last: now);
  }

  /// Takes back one counted attempt after it turned out to be right.
  void _forgiveOne(String key) {
    final f = _failures[key];
    if (f == null) return;
    if (f.count <= 1) {
      _failures.remove(key);
    } else {
      _failures[key] = (count: f.count - 1, until: f.until, last: f.last);
    }
  }

  Future<bool> _verifyInBackground(String password, String stored) async {
    if (_checksInFlight >= maxConcurrentChecks) {
      if (_checkQueue.length >= maxQueuedChecks) {
        throw const AuthException(
          "The server's busy right now. Try again in a moment.",
        );
      }
      final turn = Completer<void>();
      _checkQueue.add(turn);
      await turn.future;
    }
    _checksInFlight++;
    try {
      return await Isolate.run(() => verifyPassword(password, stored));
    } finally {
      _checksInFlight--;
      if (_checkQueue.isNotEmpty) _checkQueue.removeFirst().complete();
    }
  }

  static final _dummyHash = hashPassword('not-a-real-password');

  /// Starts a session and returns its bearer token.
  String createSession(String userId, String device) {
    final token = _token(32);
    final now = _clock().toUtc().toIso8601String();
    _db.execute(
      'INSERT INTO sessions (token_hash, user_id, device, created_at, last_seen) '
      'VALUES (?, ?, ?, ?, ?)',
      [
        _sha(token),
        userId,
        device.trim().isEmpty ? 'Device' : device.trim(),
        now,
        now,
      ],
    );
    return token;
  }

  /// The user a bearer token belongs to, or null if it isn't valid.
  /// Sessions unused for [sessionLifetime] have expired.
  User? userForToken(String token) {
    final rows = _db.select(
      'SELECT user_id, last_seen FROM sessions WHERE token_hash = ?',
      [_sha(token)],
    );
    if (rows.isEmpty) return null;
    final lastSeen = DateTime.parse(rows.first['last_seen'] as String);
    if (_clock().difference(lastSeen) > sessionLifetime) {
      endSession(token);
      return null;
    }
    _db.execute('UPDATE sessions SET last_seen = ? WHERE token_hash = ?', [
      _clock().toUtc().toIso8601String(),
      _sha(token),
    ]);
    return userById(rows.first['user_id'] as String);
  }

  void endSession(String token) =>
      _db.execute('DELETE FROM sessions WHERE token_hash = ?', [_sha(token)]);

  /// A short, non-secret name for a session: the start of its token's hash.
  static String sessionIdOf(String token) => _sha(token).substring(0, 16);

  /// Ends one of [userId]'s sessions by its id, e.g. for a lost phone.
  /// Returns whether there was one.
  bool endSessionById(String userId, String sessionId) {
    if (!RegExp(r'^[0-9a-f]{16}$').hasMatch(sessionId)) return false;
    final before = _db.select(
      "SELECT 1 FROM sessions WHERE user_id = ? AND token_hash LIKE ? || '%'",
      [userId, sessionId],
    );
    _db.execute(
      "DELETE FROM sessions WHERE user_id = ? AND token_hash LIKE ? || '%'",
      [userId, sessionId],
    );
    return before.isNotEmpty;
  }

  /// Ends all of [userId]'s sessions, except [keep] (a token) if given.
  void endSessionsFor(String userId, {String? keep}) => _db.execute(
    'DELETE FROM sessions WHERE user_id = ? AND token_hash != ?',
    [userId, keep == null ? '' : _sha(keep)],
  );

  List<Map<String, Object?>> sessionsFor(String userId, {String? current}) => [
    for (final r in _db.select(
      'SELECT token_hash, device, created_at, last_seen FROM sessions WHERE user_id = ? ORDER BY last_seen DESC',
      [userId],
    ))
      {
        'id': (r['token_hash'] as String).substring(0, 16),
        'device': r['device'],
        'createdAt': r['created_at'],
        'lastSeen': r['last_seen'],
        'current': current != null && r['token_hash'] == _sha(current),
      },
  ];

  /// A one-time code that signs a new device in as [userId]: shown as a QR
  /// code or typed, and also used to finish OIDC sign-in.
  String createCode(String userId) {
    _codes.removeWhere((_, v) => v.expires.isBefore(_clock()));
    // Unambiguous characters, grouped for typing: e.g. "K7QM-3XPT".
    const alphabet = 'ABCDEFGHJKMNPQRSTUVWXYZ23456789';
    final raw = List.generate(
      8,
      (_) => alphabet[_random.nextInt(alphabet.length)],
    ).join();
    final code = '${raw.substring(0, 4)}-${raw.substring(4)}';
    _codes[_sha(_normalizeCode(code))] = (
      userId: userId,
      expires: _clock().add(codeLifetime),
    );
    return code;
  }

  /// Exchanges a one-time code for the user it was made for. Each code works
  /// once. After 10 wrong codes, [client] waits a growing delay.
  User redeemCode(String code, {String client = ''}) {
    final key = 'code|$client';
    _checkLockout(key, 10);
    final entry = _codes.remove(_sha(_normalizeCode(code)));
    if (entry == null || entry.expires.isBefore(_clock())) {
      _recordFailure(key, 10);
      throw const AuthException(
        "That code doesn't work. It may have expired, so try getting a new one.",
      );
    }
    return userById(entry.userId) ??
        (throw const AuthException("That account doesn't exist anymore."));
  }

  /// The secret part of [userId]'s private calendar link, made on first use.
  String calendarToken(String userId) {
    final rows = _db.select(
      'SELECT token FROM calendar_links WHERE user_id = ?',
      [userId],
    );
    return rows.isEmpty ? resetCalendarToken(userId) : rows.first['token'];
  }

  /// Replaces [userId]'s calendar link; the old one stops working.
  String resetCalendarToken(String userId) {
    final token = _token(32);
    _db.execute(
      'INSERT OR REPLACE INTO calendar_links (user_id, token) VALUES (?, ?)',
      [userId, token],
    );
    return token;
  }

  /// Whose calendar link [token] is, if anyone's.
  User? userForCalendarToken(String token) {
    final rows = _db.select(
      'SELECT user_id FROM calendar_links WHERE token = ?',
      [token],
    );
    return rows.isEmpty ? null : userById(rows.first['user_id'] as String);
  }

  static String _normalizeCode(String code) =>
      code.toUpperCase().replaceAll(RegExp('[^A-Z0-9]'), '');

  String _token(int bytes) => base64Url
      .encode(List.generate(bytes, (_) => _random.nextInt(256)))
      .replaceAll('=', '');

  static String _sha(String s) => sha256.convert(utf8.encode(s)).toString();

  static String hashPassword(
    String password, {
    int iterations = passwordIterations,
  }) {
    final random = Random.secure();
    final salt = Uint8List.fromList(
      List.generate(16, (_) => random.nextInt(256)),
    );
    final key = _pbkdf2(utf8.encode(password), salt, iterations);
    return 'pbkdf2-sha256\$$iterations\$${base64.encode(salt)}\$${base64.encode(key)}';
  }

  static bool verifyPassword(String password, String stored) {
    final parts = stored.split(r'$');
    if (parts.length != 4 || parts[0] != 'pbkdf2-sha256') return false;
    final expected = base64.decode(parts[3]);
    final actual = _pbkdf2(
      utf8.encode(password),
      base64.decode(parts[2]),
      int.parse(parts[1]),
    );
    // Constant-time comparison.
    var diff = expected.length ^ actual.length;
    for (var i = 0; i < min(expected.length, actual.length); i++) {
      diff |= expected[i] ^ actual[i];
    }
    return diff == 0;
  }

  /// PBKDF2-HMAC-SHA256 producing one 32-byte block (RFC 8018).
  static List<int> _pbkdf2(List<int> password, List<int> salt, int iterations) {
    final hmac = Hmac(sha256, password);
    var u = hmac.convert([...salt, 0, 0, 0, 1]).bytes;
    final result = List<int>.of(u);
    for (var i = 1; i < iterations; i++) {
      u = hmac.convert(u).bytes;
      for (var j = 0; j < result.length; j++) {
        result[j] ^= u[j];
      }
    }
    return result;
  }
}
