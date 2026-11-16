import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:basic_utils/basic_utils.dart';
import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;

/// The OpenHabits directory every server uses unless `DIRECTORY_URL` says
/// otherwise (`DIRECTORY_URL=off` turns it off).
const officialDirectory = 'https://directory.ryanruddock.com';

/// This server's identity in the OpenHabits directory: a signing key of its
/// own (separate from the HTTPS certificate) and the ID derived from it.
///
/// The ID is what paired devices remember. When this home's internet
/// address changes, the server publishes the new one under this ID, and a
/// device away from home that can't connect asks the directory for it.
class DirectoryIdentity {
  final ECPrivateKey _key;

  /// The public key as an uncompressed P-256 point (65 bytes).
  final Uint8List publicKey;

  /// 26 lowercase base32 characters, from the first 16 bytes of the public
  /// key's SHA-256. The directory derives it the same way.
  final String id;

  DirectoryIdentity._(this._key, this.publicKey) : id = idForKey(publicKey);

  factory DirectoryIdentity.fromPem(String pem) {
    final key = CryptoUtils.ecPrivateKeyFromPem(pem);
    final point = (key.parameters!.G * key.d)!;
    return DirectoryIdentity._(key, point.getEncoded(false));
  }

  /// Loads the key from [dir], creating it on first run.
  static DirectoryIdentity loadOrCreate(Directory dir) {
    final file = File('${dir.path}/directory-key.pem');
    if (!file.existsSync()) {
      final pair = CryptoUtils.generateEcKeyPair();
      file.writeAsStringSync(
        CryptoUtils.encodeEcPrivateKeyToPem(pair.privateKey as ECPrivateKey),
      );
    }
    return DirectoryIdentity.fromPem(file.readAsStringSync());
  }

  /// An ECDSA P-256 / SHA-256 signature in the raw r‖s form WebCrypto uses.
  Uint8List sign(List<int> data) {
    final sig = CryptoUtils.ecSign(
      _key,
      Uint8List.fromList(data),
      algorithmName: 'SHA-256/ECDSA',
    );
    return Uint8List.fromList([..._fixed32(sig.r), ..._fixed32(sig.s)]);
  }

  static List<int> _fixed32(BigInt n) {
    final out = List<int>.filled(32, 0);
    for (var i = 31; i >= 0 && n > BigInt.zero; i--) {
      out[i] = (n & BigInt.from(0xff)).toInt();
      n = n >> 8;
    }
    return out;
  }

  static String idForKey(List<int> publicKey) =>
      _base32(sha256.convert(publicKey).bytes.sublist(0, 16));

  static String _base32(List<int> bytes) {
    const alphabet = 'abcdefghijklmnopqrstuvwxyz234567';
    var bits = 0, value = 0;
    final out = StringBuffer();
    for (final byte in bytes) {
      value = ((value << 8) | byte) & 0xffff;
      bits += 8;
      while (bits >= 5) {
        out.write(alphabet[(value >> (bits - 5)) & 31]);
        bits -= 5;
      }
    }
    if (bits > 0) out.write(alphabet[(value << (5 - bits)) & 31]);
    return out.toString();
  }
}

/// Publishes this server's current addresses to the directory.
class DirectoryClient {
  /// e.g. https://directory.example.com
  final Uri base;
  final DirectoryIdentity identity;
  final http.Client _http;
  final DateTime Function() _now;

  DirectoryClient(
    this.base,
    this.identity, {
    http.Client? client,
    DateTime Function()? now,
  }) : _http = client ?? http.Client(),
       _now = now ?? DateTime.now;

  /// Where devices look this server up.
  Uri get lookupUrl => base.resolve('/v1/servers/${identity.id}');

  /// Tells the directory where this server can be reached. An empty list
  /// removes the entry (remote access turned off). Throws on failure.
  Future<void> publish(List<String> urls) async {
    final payload = jsonEncode({
      'id': identity.id,
      'urls': urls,
      'ts': _now().millisecondsSinceEpoch,
    });
    final body = jsonEncode({
      'key': _base64Url(identity.publicKey),
      'payload': payload,
      'sig': _base64Url(identity.sign(utf8.encode(payload))),
    });
    final response = await _http
        .put(
          lookupUrl,
          headers: {'content-type': 'application/json'},
          body: body,
        )
        .timeout(const Duration(seconds: 10));
    if (response.statusCode != 200) {
      String reason;
      try {
        reason = (jsonDecode(response.body) as Map)['error'] as String;
      } catch (_) {
        reason = 'error ${response.statusCode}';
      }
      throw HttpException('The directory refused the update: $reason');
    }
  }

  static String _base64Url(List<int> bytes) =>
      base64Url.encode(bytes).replaceAll('=', '');
}
