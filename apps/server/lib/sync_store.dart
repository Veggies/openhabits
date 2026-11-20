import 'dart:convert';
import 'dart:math';

import 'package:core/core.dart';
import 'package:sqlite3/sqlite3.dart';

/// Server-side sync state: the winning change for every field of every
/// person's data, stamped with a server sequence number so devices can pull
/// everything newer than the last sequence they saw.
class SyncStore {
  final Database db;
  late int _seq;
  late Hlc _clock;

  SyncStore(this.db) {
    _migrate();
    _seq = _maxSeq();
    // Databases from before history tags start their history here.
    db.execute('INSERT OR IGNORE INTO history (seq, tag) VALUES (?, ?)', [
      _seq,
      _newTag(),
    ]);
    // Packed HLCs sort as text, so MAX finds the latest one written.
    final latest =
        db.select('SELECT MAX(hlc) AS h FROM fields').first['h'] as String?;
    _clock = latest == null
        ? const Hlc.zero(serverNodeId)
        : const Hlc.zero(serverNodeId).receive(Hlc.parse(latest), _now());
  }

  factory SyncStore.open(String path) => SyncStore(sqlite3.open(path));

  factory SyncStore.inMemory() => SyncStore(sqlite3.openInMemory());

  void _migrate() {
    final columns = {
      for (final r in db.select("PRAGMA table_info('fields')")) r['name'],
    };
    if (columns.isNotEmpty && !columns.contains('user_id')) {
      // Data from before accounts existed. It's kept under an empty user id
      // and handed to the owner when the owner account is created.
      db.execute('ALTER TABLE fields RENAME TO fields_v1');
    }
    db.execute('''
      CREATE TABLE IF NOT EXISTS fields (
        user_id TEXT NOT NULL,
        tbl TEXT NOT NULL,
        row_id TEXT NOT NULL,
        field TEXT NOT NULL,
        value TEXT,
        hlc TEXT NOT NULL,
        seq INTEGER NOT NULL,
        PRIMARY KEY (user_id, tbl, row_id, field)
      );
      CREATE INDEX IF NOT EXISTS fields_user_seq ON fields (user_id, seq);
      -- A random tag for every point the cursor has stopped at. Devices
      -- send back the tag they were given; if it isn't here, the server
      -- was restored from a backup taken before that point, even if the
      -- cursor has since counted back up past it.
      CREATE TABLE IF NOT EXISTS history (
        seq INTEGER PRIMARY KEY,
        tag TEXT NOT NULL
      );
    ''');
    if (columns.isNotEmpty && !columns.contains('user_id')) {
      db.execute(
        "INSERT INTO fields SELECT '', tbl, row_id, field, value, hlc, seq FROM fields_v1",
      );
      db.execute('DROP TABLE fields_v1');
    }
  }

  // History is included because deleting someone's data can remove the
  // fields with the highest sequence numbers, and a sequence must never be
  // reused: devices past it would miss what's written there next.
  int _maxSeq() =>
      db
              .select(
                'SELECT MAX(COALESCE((SELECT MAX(seq) FROM fields), 0), '
                'COALESCE((SELECT MAX(seq) FROM history), 0)) AS s',
              )
              .first['s']
          as int;

  /// Gives data stored without an owner (from before accounts) to [userId].
  void adoptUnownedData(String userId) =>
      db.execute("UPDATE fields SET user_id = ? WHERE user_id = ''", [userId]);

  /// Node id for changes the server makes itself, e.g. calendar imports.
  static const serverNodeId = 'server';

  static int _now() => DateTime.now().millisecondsSinceEpoch;

  /// A timestamp for a server-made change, ordered after everything seen.
  Hlc stamp() => _clock = _clock.send(_now());

  int get cursor => _seq;

  static final _random = Random.secure();

  static String _newTag() => [
    for (var i = 0; i < 8; i++)
      _random.nextInt(256).toRadixString(16).padLeft(2, '0'),
  ].join();

  /// The tag for the current [cursor], sent to devices along with it.
  String get cursorTag =>
      db.select('SELECT tag FROM history WHERE seq = ?', [_seq]).first['tag']
          as String;

  /// Whether this server's history includes the point a device was given
  /// as [seq] and [tag]. It doesn't after a restore from a backup taken
  /// before that point.
  bool knows(int seq, String tag) => db.select(
    'SELECT 1 FROM history WHERE seq = ? AND tag = ?',
    [seq, tag],
  ).isNotEmpty;

  /// Applies [changes] to [userId]'s data using the shared merge rule.
  /// Returns how many won.
  int apply(String userId, List<Change> changes) {
    final read = db.prepare(
      'SELECT hlc FROM fields WHERE user_id = ? AND tbl = ? AND row_id = ? AND field = ?',
    );
    final write = db.prepare(
      'INSERT OR REPLACE INTO fields (user_id, tbl, row_id, field, value, hlc, seq) '
      'VALUES (?, ?, ?, ?, ?, ?, ?)',
    );
    var applied = 0;
    db.execute('BEGIN');
    try {
      for (final change in changes) {
        final rows = read.select([
          userId,
          change.table,
          change.rowId,
          change.field,
        ]);
        final current = rows.isEmpty
            ? null
            : Change(
                table: change.table,
                rowId: change.rowId,
                field: change.field,
                value: null,
                hlc: Hlc.parse(rows.first['hlc'] as String),
              );
        _clock = _clock.receive(change.hlc, _now());
        if (!shouldApply(change, current)) continue;
        write.execute([
          userId,
          change.table,
          change.rowId,
          change.field,
          jsonEncode(change.value),
          change.hlc.pack(),
          ++_seq,
        ]);
        applied++;
      }
      if (applied > 0) {
        db.execute('INSERT INTO history (seq, tag) VALUES (?, ?)', [
          _seq,
          _newTag(),
        ]);
      }
      db.execute('COMMIT');
    } catch (_) {
      db.execute('ROLLBACK');
      _seq = _maxSeq();
      rethrow;
    } finally {
      read.close();
      write.close();
    }
    return applied;
  }

  /// Every field of [userId]'s data whose winning value changed after [since].
  List<Change> changesSince(String userId, int since) => [
    for (final row in db.select(
      'SELECT tbl, row_id, field, value, hlc FROM fields '
      'WHERE user_id = ? AND seq > ? ORDER BY seq',
      [userId, since],
    ))
      Change(
        table: row['tbl'] as String,
        rowId: row['row_id'] as String,
        field: row['field'] as String,
        value: jsonDecode(row['value'] as String),
        hlc: Hlc.parse(row['hlc'] as String),
      ),
  ];

  /// Every row of [userId]'s [table] (including deleted ones) as field maps.
  Map<String, Map<String, Object?>> rows(String userId, String table) {
    final result = <String, Map<String, Object?>>{};
    for (final row in db.select(
      'SELECT row_id, field, value FROM fields WHERE user_id = ? AND tbl = ?',
      [userId, table],
    )) {
      result.putIfAbsent(row['row_id'] as String, () => {})[row['field']
          as String] = jsonDecode(
        row['value'] as String,
      );
    }
    return result;
  }

  /// Removes all of [userId]'s data.
  void deleteUserData(String userId) =>
      db.execute('DELETE FROM fields WHERE user_id = ?', [userId]);

  void close() => db.close();
}
