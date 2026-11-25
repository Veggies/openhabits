import 'dart:convert';
import 'dart:math';

import 'package:core/core.dart';
import 'package:flutter/foundation.dart';
import 'package:sqlite3/sqlite3.dart';

/// The device's copy of all synced data.
///
/// Every row is kept in memory as a field map (habit data is small)
/// and persisted to SQLite. Local edits are applied immediately and queued
/// in an outbox until the sync engine delivers them to the server.
class LocalStore extends ChangeNotifier {
  final Database _db;
  final _tables = <String, Map<String, Fields>>{};
  final _hlcs = <(String, String, String), Hlc>{};
  late Hlc _clock;
  late final String nodeId;

  LocalStore(this._db) {
    _db.execute('''
      CREATE TABLE IF NOT EXISTS fields (
        tbl TEXT NOT NULL,
        row_id TEXT NOT NULL,
        field TEXT NOT NULL,
        value TEXT,
        hlc TEXT NOT NULL,
        PRIMARY KEY (tbl, row_id, field)
      );
      CREATE TABLE IF NOT EXISTS outbox (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        change TEXT NOT NULL
      );
      CREATE TABLE IF NOT EXISTS meta (key TEXT PRIMARY KEY, value TEXT);
    ''');
    nodeId = meta('nodeId') ?? _newNodeId();
    var clock = Hlc.zero(nodeId);
    for (final row in _db.select('SELECT * FROM fields')) {
      final hlc = Hlc.parse(row['hlc'] as String);
      _put(
        row['tbl'] as String,
        row['row_id'] as String,
        row['field'] as String,
        jsonDecode(row['value'] as String),
        hlc,
      );
      clock = clock.receive(hlc, DateTime.now().millisecondsSinceEpoch);
    }
    _clock = clock;
  }

  factory LocalStore.open(String path) => LocalStore(sqlite3.open(path));

  factory LocalStore.inMemory() => LocalStore(sqlite3.openInMemory());

  String _newNodeId() {
    final id = _randomId(8);
    setMeta('nodeId', id);
    return id;
  }

  static final _random = Random.secure();

  static String _randomId(int bytes) => [
    for (var i = 0; i < bytes; i++)
      _random.nextInt(256).toRadixString(16).padLeft(2, '0'),
  ].join();

  /// A new globally unique row id.
  String newId() => _randomId(12);

  /// All rows in [table], including deleted ones.
  Map<String, Fields> table(String table) => _tables[table] ?? const {};

  Fields? row(String table, String id) => _tables[table]?[id];

  /// Sets [fields] on a row, creating it if needed, and queues the change.
  void write(String table, String rowId, Fields fields) {
    if (fields.isEmpty) return;
    final hlc = _clock = _clock.send(DateTime.now().millisecondsSinceEpoch);
    final changes = [
      for (final MapEntry(:key, :value) in fields.entries)
        Change(
          table: table,
          rowId: rowId,
          field: key,
          value: value,
          hlc: _after(_hlcs[(table, rowId, key)], hlc),
        ),
    ];
    final staged = <(String, String, String), Change>{};
    _db.execute('BEGIN');
    try {
      final queue = _db.prepare('INSERT INTO outbox (change) VALUES (?)');
      for (final c in changes) {
        _persist(c, staged);
        queue.execute([jsonEncode(c.toJson())]);
      }
      queue.close();
      _db.execute('COMMIT');
    } catch (_) {
      _db.execute('ROLLBACK');
      rethrow;
    }
    _keep(staged);
    notifyListeners();
  }

  /// [hlc], or just after [current] if that's later. A field last written
  /// by a device whose date was set far ahead keeps that future timestamp;
  /// without this, every later edit to it would lose until the real date
  /// caught up.
  Hlc _after(Hlc? current, Hlc hlc) => current == null || hlc > current
      ? hlc
      : Hlc(current.millis, current.counter + 1, nodeId);

  /// Applies changes received from the server and records the new cursor.
  /// [cursorTag] is the server's tag for that point in its history, sent
  /// back next time so it can tell if it was restored from a backup.
  /// Servers from before tags don't send one.
  void applyRemote(List<Change> changes, int cursor, {String? cursorTag}) {
    final now = DateTime.now().millisecondsSinceEpoch;
    final staged = <(String, String, String), Change>{};
    _db.execute('BEGIN');
    try {
      for (final c in changes) {
        _clock = _clock.receive(c.hlc, now);
        _persist(c, staged);
      }
      setMeta('cursor', '$cursor');
      setMeta('cursorTag', cursorTag);
      _db.execute('COMMIT');
    } catch (_) {
      _db.execute('ROLLBACK');
      rethrow;
    }
    _keep(staged);
    if (staged.isNotEmpty) notifyListeners();
  }

  /// Writes [c] to the database if it wins, and notes it in [staged]. The
  /// in-memory copy is only updated by [_keep], after the database has
  /// committed, so a failed save can't leave the two disagreeing.
  void _persist(Change c, Map<(String, String, String), Change> staged) {
    final key = (c.table, c.rowId, c.field);
    final currentHlc = staged[key]?.hlc ?? _hlcs[key];
    final current = currentHlc == null
        ? null
        : Change(
            table: c.table,
            rowId: c.rowId,
            field: c.field,
            value: null,
            hlc: currentHlc,
          );
    if (!shouldApply(c, current)) return;
    _db.execute(
      'INSERT OR REPLACE INTO fields (tbl, row_id, field, value, hlc) VALUES (?, ?, ?, ?, ?)',
      [c.table, c.rowId, c.field, jsonEncode(c.value), c.hlc.pack()],
    );
    staged[key] = c;
  }

  void _keep(Map<(String, String, String), Change> staged) {
    for (final c in staged.values) {
      _put(c.table, c.rowId, c.field, c.value, c.hlc);
    }
  }

  void _put(String table, String rowId, String field, Object? value, Hlc hlc) {
    (_tables[table] ??= {}).putIfAbsent(rowId, () => {})[field] = value;
    _hlcs[(table, rowId, field)] = hlc;
  }

  /// Deletes all synced data and queued changes, e.g. when a different
  /// person signs in on this device. Device settings in meta are kept.
  void reset() {
    _db.execute('DELETE FROM fields');
    _db.execute('DELETE FROM outbox');
    setMeta('cursor', '0');
    setMeta('cursorTag', null);
    _tables.clear();
    _hlcs.clear();
    notifyListeners();
  }

  int get cursor => int.tryParse(meta('cursor') ?? '') ?? 0;

  int get pendingCount =>
      _db.select('SELECT COUNT(*) AS n FROM outbox').first['n'] as int;

  /// The oldest queued changes, with the outbox id of the last one. A
  /// queued change that can't be read is skipped (and removed when the
  /// batch is sent), so it can't hold up everything after it.
  ({List<Change> changes, int lastId}) pending({int limit = 500}) {
    final rows = _db.select(
      'SELECT id, change FROM outbox ORDER BY id LIMIT ?',
      [limit],
    );
    final changes = <Change>[];
    for (final r in rows) {
      try {
        changes.add(
          Change.fromJson(
            jsonDecode(r['change'] as String) as Map<String, Object?>,
          ),
        );
      } catch (_) {
        // Unreadable: dropped.
      }
    }
    return (
      changes: changes,
      lastId: rows.isEmpty ? 0 : rows.last['id'] as int,
    );
  }

  /// Queues every field this device has, to send it all to the server
  /// again: after the server was restored from a backup or reinstalled, it
  /// may be missing things it once had. The server ignores what it already
  /// has, so sending too much is harmless.
  void requeueAll() {
    _db.execute('BEGIN');
    try {
      final queue = _db.prepare('INSERT INTO outbox (change) VALUES (?)');
      for (final MapEntry(key: (table, rowId, field), value: hlc)
          in _hlcs.entries) {
        queue.execute([
          jsonEncode(
            Change(
              table: table,
              rowId: rowId,
              field: field,
              value: _tables[table]?[rowId]?[field],
              hlc: hlc,
            ).toJson(),
          ),
        ]);
      }
      queue.close();
      setMeta('cursor', '0');
      setMeta('cursorTag', null);
      _db.execute('COMMIT');
    } catch (_) {
      _db.execute('ROLLBACK');
      rethrow;
    }
  }

  void markSent(int lastId) =>
      _db.execute('DELETE FROM outbox WHERE id <= ?', [lastId]);

  String? meta(String key) {
    final rows = _db.select('SELECT value FROM meta WHERE key = ?', [key]);
    return rows.isEmpty ? null : rows.first['value'] as String?;
  }

  void setMeta(String key, String? value) {
    _db.execute('INSERT OR REPLACE INTO meta (key, value) VALUES (?, ?)', [
      key,
      value,
    ]);
  }

  @override
  void dispose() {
    _db.close();
    super.dispose();
  }
}
