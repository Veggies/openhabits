import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;

/// Settings for "Sign in with …" via OpenID Connect (Google, Authentik,
/// Authelia, Keycloak, …). Configured with environment variables.
class OidcConfig {
  final Uri issuer;
  final String clientId;
  final String clientSecret;

  /// Button label in the app, e.g. "Google".
  final String label;

  /// The server's public address; the provider redirects back to
  /// `<publicUrl>/auth/oidc/callback`, which must be registered with it.
  final Uri publicUrl;

  OidcConfig({
    required this.issuer,
    required this.clientId,
    required this.clientSecret,
    required this.label,
    required this.publicUrl,
  });

  static OidcConfig? fromEnv(Map<String, String> env) {
    final issuer = env['OIDC_ISSUER'];
    final clientId = env['OIDC_CLIENT_ID'];
    final publicUrl = env['PUBLIC_URL'];
    if (issuer == null ||
        issuer.isEmpty ||
        clientId == null ||
        clientId.isEmpty) {
      return null;
    }
    if (publicUrl == null || publicUrl.isEmpty) {
      throw StateError(
        'OIDC needs PUBLIC_URL set to the server\'s public address.',
      );
    }
    return OidcConfig(
      issuer: Uri.parse(issuer.replaceAll(RegExp(r'/+$'), '')),
      clientId: clientId,
      clientSecret: env['OIDC_CLIENT_SECRET'] ?? '',
      label: env['OIDC_LABEL'] ?? 'SSO',
      publicUrl: Uri.parse(publicUrl.replaceAll(RegExp(r'/+$'), '')),
    );
  }

  Uri get callbackUrl =>
      publicUrl.replace(path: '${publicUrl.path}/auth/oidc/callback');
}

class OidcException implements Exception {
  final String message;
  const OidcException(this.message);

  @override
  String toString() => message;
}

/// Runs the authorization-code flow with PKCE.
class OidcProvider {
  final OidcConfig config;
  final http.Client _http;
  final DateTime Function() _clock;
  final _random = Random.secure();
  final _pending =
      <
        String,
        ({String appRedirect, String verifier, String nonce, DateTime expires})
      >{};
  Map<String, Object?>? _discovery;

  OidcProvider(this.config, {http.Client? client, DateTime Function()? clock})
    : _http = client ?? http.Client(),
      _clock = clock ?? DateTime.now;

  /// Only the app's own callback addresses are allowed, so this flow can't
  /// be used to send people (or codes) to other sites.
  static bool isAllowedAppRedirect(Uri uri) =>
      uri.scheme == 'tasks' ||
      (uri.scheme == 'http' &&
          (uri.host == 'localhost' || uri.host == '127.0.0.1'));

  Future<Map<String, Object?>> _metadata() async {
    if (_discovery != null) return _discovery!;
    final url = config.issuer.replace(
      path: '${config.issuer.path}/.well-known/openid-configuration',
    );
    final response = await _http.get(url);
    if (response.statusCode != 200) {
      throw OidcException(
        'Could not load OIDC settings from $url (HTTP ${response.statusCode}).',
      );
    }
    return _discovery = jsonDecode(response.body) as Map<String, Object?>;
  }

  String _randomString() => base64Url
      .encode(List.generate(32, (_) => _random.nextInt(256)))
      .replaceAll('=', '');

  /// The provider's sign-in page for a flow that ends at [appRedirect].
  Future<Uri> start(Uri appRedirect) async {
    if (!isAllowedAppRedirect(appRedirect)) {
      throw const OidcException('Invalid app redirect.');
    }
    final metadata = await _metadata();
    _pending.removeWhere((_, v) => v.expires.isBefore(_clock()));
    final state = _randomString();
    final verifier = _randomString();
    final nonce = _randomString();
    _pending[state] = (
      appRedirect: appRedirect.toString(),
      verifier: verifier,
      nonce: nonce,
      expires: _clock().add(const Duration(minutes: 10)),
    );
    final challenge = base64Url
        .encode(sha256.convert(utf8.encode(verifier)).bytes)
        .replaceAll('=', '');
    return Uri.parse(metadata['authorization_endpoint'] as String).replace(
      queryParameters: {
        'response_type': 'code',
        'client_id': config.clientId,
        'redirect_uri': config.callbackUrl.toString(),
        'scope': 'openid email profile',
        'state': state,
        'nonce': nonce,
        'code_challenge': challenge,
        'code_challenge_method': 'S256',
        'prompt': 'select_account',
      },
    );
  }

  /// Completes the flow. Returns the verified email and where to send the
  /// app afterwards.
  Future<({String email, String appRedirect})> finish(
    String state,
    String code,
  ) async {
    final pending = _pending.remove(state);
    if (pending == null || pending.expires.isBefore(_clock())) {
      throw const OidcException(
        'This sign-in link has expired. Please try again.',
      );
    }
    final metadata = await _metadata();
    final response = await _http.post(
      Uri.parse(metadata['token_endpoint'] as String),
      body: {
        'grant_type': 'authorization_code',
        'code': code,
        'redirect_uri': config.callbackUrl.toString(),
        'client_id': config.clientId,
        'client_secret': config.clientSecret,
        'code_verifier': pending.verifier,
      },
    );
    if (response.statusCode != 200) {
      throw OidcException(
        'The sign-in provider rejected the request (HTTP ${response.statusCode}).',
      );
    }
    final idToken = (jsonDecode(response.body) as Map)['id_token'] as String?;
    if (idToken == null) {
      throw const OidcException('The provider did not return an ID token.');
    }

    // The token came straight from the provider over TLS, so the signature
    // check can be replaced by TLS server validation (OIDC Core 3.1.3.7).
    // The claims themselves are still checked.
    final claims = decodeJwtPayload(idToken);
    final aud = claims['aud'];
    final audiences = aud is List ? aud : [aud];
    final exp = claims['exp'] as int? ?? 0;
    if (claims['iss'] != metadata['issuer'] ||
        !audiences.contains(config.clientId) ||
        exp * 1000 < _clock().millisecondsSinceEpoch ||
        claims['nonce'] != pending.nonce) {
      throw const OidcException('The sign-in response could not be verified.');
    }
    final email = claims['email'] as String?;
    if (email == null || claims['email_verified'] == false) {
      throw const OidcException('Your account has no verified email address.');
    }
    return (email: email, appRedirect: pending.appRedirect);
  }
}

Map<String, Object?> decodeJwtPayload(String jwt) {
  final parts = jwt.split('.');
  if (parts.length < 2) throw const OidcException('Malformed ID token.');
  return jsonDecode(
    utf8.decode(base64Url.decode(base64Url.normalize(parts[1]))),
  ) as Map<String, Object?>;
}
