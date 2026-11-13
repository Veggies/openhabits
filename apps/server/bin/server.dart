import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:server/api.dart';
import 'package:server/auth/auth_store.dart';
import 'package:server/auth/oidc.dart';
import 'package:server/calendar/calendar_sync.dart';
import 'package:server/remote/remote_access.dart';
import 'package:server/remote/tls.dart';
import 'package:server/settings_store.dart';
import 'package:server/sync_store.dart';
import 'package:shelf/shelf.dart';
import 'package:shelf/shelf_io.dart';
import 'package:timezone/data/latest.dart' as tz;

Future<void> main(List<String> args) async {
  final env = Platform.environment;
  final port = int.parse(env['PORT'] ?? '8080');
  final httpsPort = int.parse(env['HTTPS_PORT'] ?? '8443');

  // Used by the container health check (the image has no curl).
  if (args.contains('--healthcheck')) {
    try {
      final response = await http
          .get(Uri.parse('http://127.0.0.1:$port/health'))
          .timeout(const Duration(seconds: 5));
      exit(response.statusCode == 200 ? 0 : 1);
    } catch (_) {
      exit(1);
    }
  }

  tz.initializeTimeZones();
  final dbPath = env['DB_PATH'] ?? 'data.sqlite';
  final dataDir = File(dbPath).absolute.parent;
  final store = SyncStore.open(dbPath);
  final auth = AuthStore(store);
  final settings = SettingsStore(store.db);

  // Optional: create the owner from the environment for unattended installs.
  // Normally the setup page does this.
  final ownerName = env['OWNER_USERNAME'] ?? '';
  final ownerPassword = env['OWNER_PASSWORD'] ?? '';
  if (!auth.hasUsers && ownerName.isNotEmpty && ownerPassword.isNotEmpty) {
    final owner = auth.createUser(
      ownerName,
      password: ownerPassword,
      email: env['OWNER_EMAIL'],
    );
    print('Created owner account "${owner.username}".');
  }

  // An address configured outside the setup page (e.g. in the TrueNAS app
  // form) becomes the custom public address.
  final envPublicUrl = env['PUBLIC_URL'] ?? '';
  if (envPublicUrl.isNotEmpty) {
    settings.publicUrl = envPublicUrl;
    settings.remoteEnabled = true;
  }

  final certificate = ServerCertificate.loadOrCreate(dataDir);
  final remote = RemoteAccess(settings, httpsPort: httpsPort)..start();

  // Calendars used to live in calendars.json; bring them into settings once.
  final legacyCalendars = File(
    env['CALENDARS_CONFIG'] ?? '${dataDir.path}/calendars.json',
  );
  if (settings.calendars.isEmpty && legacyCalendars.existsSync()) {
    final json = jsonDecode(legacyCalendars.readAsStringSync());
    final list = json is Map ? json['calendars'] : json;
    settings.calendars = [
      for (final c in list as List) (c as Map).cast<String, Object?>(),
    ];
    print(
      'Imported ${settings.calendars.length} calendar(s) from ${legacyCalendars.path}.',
    );
  }
  final calendars = CalendarSync(
    store,
    [for (final c in settings.calendars) CalendarSource.fromJson(c)],
    userIdFor: (s) =>
        s.user == null ? auth.owner?.id : auth.userByName(s.user!)?.id,
  );
  final minutes = int.parse(env['CALENDAR_SYNC_MINUTES'] ?? '15');
  unawaited(calendars.run());
  Timer.periodic(Duration(minutes: minutes), (_) => calendars.run());

  // Single sign-on: from the environment if set, otherwise from the setup
  // page. Rebuilt whenever the owner changes it.
  OidcProvider? oidc;
  void configureSso() {
    final s = settings.sso;
    final base = settings.publicUrl;
    final config =
        OidcConfig.fromEnv(env) ??
        ((s['issuer'] ?? '').isEmpty ||
                (s['clientId'] ?? '').isEmpty ||
                base == null
            ? null
            : OidcConfig(
                issuer: Uri.parse(s['issuer']!.replaceAll(RegExp(r'/+$'), '')),
                clientId: s['clientId']!,
                clientSecret: s['clientSecret'] ?? '',
                label: s['label'] ?? 'SSO',
                publicUrl: Uri.parse(base),
              ));
    oidc = config == null ? null : OidcProvider(config);
  }

  configureSso();

  final handler = const Pipeline()
      .addMiddleware(logRequests())
      .addHandler(
        buildHandler(
          store,
          auth,
          calendars: calendars,
          serverName: env['SERVER_NAME'] ?? settings.serverName,
          trustProxy: env['TRUST_PROXY'] == 'true',
          settings: settings,
          remote: remote,
          fingerprint: certificate.fingerprint,
          currentOidc: () => oidc,
          onSettingsChanged: configureSso,
        ),
      );

  // Plain HTTP for the home network and the setup page; HTTPS with the
  // server's own certificate for remote access.
  final server = await serve(handler, InternetAddress.anyIPv4, port);
  await serve(
    handler,
    InternetAddress.anyIPv4,
    httpsPort,
    securityContext: certificate.securityContext,
  );
  print(
    'Server listening on port ${server.port} (HTTPS for remote access on $httpsPort)',
  );
  print(
    auth.hasUsers
        ? 'Setup page: http://<this-server>:${server.port}'
        : 'Finish setup in your browser: http://<this-server>:${server.port}',
  );
}
