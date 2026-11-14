import 'dart:convert';
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

  /// Failed sign-ins per client, for rate limiting.
  final _failures = <String, ({int count, DateTime until})>{};

  static const passwordIterations = 120000;
  static const codeLifetime = Duration(minutes: 10);

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

  void deleteUser(String id) {
    final user = userById(id);
    if (user == null) return;
    if (user.isOwner) throw const AuthException("The owner can't be removed.");
    _db.execute('DELETE FROM sessions WHERE user_id = ?', [id]);
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
  /// its IP) for rate limiting: after 5 failures, sign-in is refused for a
  /// growing delay.
  User signIn(String username, String password, {String client = ''}) {
    final now = _clock();
    final failures = _failures[client];
    if (failures != null &&
        failures.count >= 5 &&
        now.isBefore(failures.until)) {
      final wait = failures.until.difference(now).inSeconds + 1;
      throw AuthException(
        "That's too many tries for now. Wait $wait seconds and try again.",
      );
    }
    final rows = _db.select('SELECT * FROM users WHERE username = ?', [
      username.trim(),
    ]);
    final hash = rows.isEmpty ? null : rows.first['password_hash'] as String?;
    // Verify even for unknown users so response time doesn't reveal them.
    final ok = verifyPassword(password, hash ?? _dummyHash);
    if (rows.isEmpty || hash == null || !ok) {
      final count = (failures?.count ?? 0) + 1;
      final lockout = Duration(
        seconds: count < 5 ? 0 : 30 * (1 << min(count - 5, 6)),
      );
      _failures[client] = (count: count, until: now.add(lockout));
      throw const AuthException("That username or password isn't right.");
    }
    _failures.remove(client);
    return _toUser(rows.first);
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
  User? userForToken(String token) {
    final rows = _db.select(
      'SELECT user_id FROM sessions WHERE token_hash = ?',
      [_sha(token)],
    );
    if (rows.isEmpty) return null;
    _db.execute('UPDATE sessions SET last_seen = ? WHERE token_hash = ?', [
      _clock().toUtc().toIso8601String(),
      _sha(token),
    ]);
    return userById(rows.first['user_id'] as String);
  }

  void endSession(String token) =>
      _db.execute('DELETE FROM sessions WHERE token_hash = ?', [_sha(token)]);

  List<Map<String, Object?>> sessionsFor(String userId) => [
    for (final r in _db.select(
      'SELECT device, created_at, last_seen FROM sessions WHERE user_id = ? ORDER BY last_seen DESC',
      [userId],
    ))
      {
        'device': r['device'],
        'createdAt': r['created_at'],
        'lastSeen': r['last_seen'],
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
  /// once.
  User redeemCode(String code) {
    final entry = _codes.remove(_sha(_normalizeCode(code)));
    if (entry == null || entry.expires.isBefore(_clock())) {
      throw const AuthException(
        "That code doesn't work. It may have expired, so try getting a new one.",
      );
    }
    return userById(entry.userId) ??
        (throw const AuthException("That account doesn't exist anymore."));
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
