import 'dart:async';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:server/api.dart';
import 'package:server/auth/auth_store.dart';
import 'package:server/auth/oidc.dart';
import 'package:server/remote/directory.dart';
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

  // An address set outside the setup page (e.g. in the TrueNAS app form).
  settings.applyEnvPublicUrl(env['PUBLIC_URL'] ?? '');

  final certificate = ServerCertificate.loadOrCreate(dataDir);
  // The server's own signing key. Its id is how devices recognise this
  // server, and it signs what the server publishes to the directory.
  final identity = DirectoryIdentity.loadOrCreate(dataDir);
  // The address book devices use to find this server after its internet
  // address changes. DIRECTORY_URL=off turns it off.
  final directoryUrl = env['DIRECTORY_URL'] ?? officialDirectory;
  final directory = directoryUrl == 'off'
      ? null
      : DirectoryClient(Uri.parse(directoryUrl), identity);
  final remote = RemoteAccess(
    settings,
    httpsPort: httpsPort,
    directory: directory,
  )..start();

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
      .addMiddleware(
        logRequests(
          logger: (message, isError) => isError
              ? stderr.writeln(redactLogLine(message))
              : print(redactLogLine(message)),
        ),
      )
      .addHandler(
        buildHandler(
          store,
          auth,
          serverName: env['SERVER_NAME'] ?? settings.serverName,
          trustProxy: ProxyTrust.parse(env['TRUST_PROXY']),
          serverId: identity.id,
          serverKey: identity.publicKeyBase64Url,
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
