import 'dart:convert';

import 'package:sqlite3/sqlite3.dart';

/// Server settings changed from the setup page, stored in the database so
/// they survive restarts and container updates.
class SettingsStore {
  final Database _db;

  SettingsStore(this._db) {
    _db.execute(
      'CREATE TABLE IF NOT EXISTS settings (key TEXT PRIMARY KEY, value TEXT NOT NULL)',
    );
  }

  Object? get(String key) {
    final rows = _db.select('SELECT value FROM settings WHERE key = ?', [key]);
    return rows.isEmpty ? null : jsonDecode(rows.first['value'] as String);
  }

  void set(String key, Object? value) {
    if (value == null) {
      _db.execute('DELETE FROM settings WHERE key = ?', [key]);
    } else {
      _db.execute(
        'INSERT OR REPLACE INTO settings (key, value) VALUES (?, ?)',
        [key, jsonEncode(value)],
      );
    }
  }

  bool get remoteEnabled => get('remoteEnabled') == true;
  set remoteEnabled(bool v) => set('remoteEnabled', v);

  /// The person forwarded the port on their router themselves.
  bool get remoteManual => get('remoteManual') == true;
  set remoteManual(bool v) => set('remoteManual', v);

  /// The port opened on the router.
  int get remotePort => get('remotePort') as int? ?? 8443;
  set remotePort(int v) => set('remotePort', v);

  /// What was last sent to the directory: addresses and when, so it's only
  /// updated when they change (and weekly, to stay listed).
  ({List<String> urls, DateTime at})? get directoryPublished {
    final v = get('directoryPublished') as Map?;
    if (v == null) return null;
    return (
      urls: (v['urls'] as List).cast<String>(),
      at: DateTime.fromMillisecondsSinceEpoch(v['at'] as int),
    );
  }

  set directoryPublished(({List<String> urls, DateTime at})? v) => set(
    'directoryPublished',
    v == null ? null : {'urls': v.urls, 'at': v.at.millisecondsSinceEpoch},
  );

  /// A public address that reaches this server some other way (Tailscale
  /// Funnel, a reverse proxy on your own domain). Overrides the automatic
  /// one.
  String? get publicUrl => get('publicUrl') as String?;
  set publicUrl(String? v) => set(
    'publicUrl',
    v == null || v.trim().isEmpty
        ? null
        : v.trim().replaceAll(RegExp(r'/+$'), ''),
  );

  /// Single sign-on: issuer, clientId, clientSecret, label.
  Map<String, String> get sso => {
    for (final MapEntry(:key, :value)
        in (get('sso') as Map? ?? const {}).entries)
      '$key': '$value',
  };
  set sso(Map<String, String> v) => set('sso', v);

  /// The last address that worked, offered while re-checking after a
  /// restart.
  String? get lastRemoteUrl => get('lastRemoteUrl') as String?;
  set lastRemoteUrl(String? v) => set('lastRemoteUrl', v);

  String get serverName => get('serverName') as String? ?? 'OpenHabits';
}
