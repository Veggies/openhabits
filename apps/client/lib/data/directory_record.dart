import 'dart:convert';
import 'dart:typed_data';

import 'package:pointycastle/export.dart';

/// An answer from the OpenHabits directory, checked against the server's
/// own key.
///
/// The server signs every update it sends the directory, and the directory
/// passes that signed update on unchanged. This device learned the server's
/// key when it signed in, so it can tell an address the server published
/// from one the directory (or anyone in between) made up. Matches
/// DirectoryRecord.swift.
class DirectoryRecord {
  final List<String> urls;

  /// When the server signed it, in milliseconds.
  final int ts;

  const DirectoryRecord._(this.urls, this.ts);

  /// The record in [response], or null unless it was signed with [key]
  /// (base64url, an uncompressed P-256 point), is for [id], and is no older
  /// than [notBefore].
  static DirectoryRecord? verify(
    Map<String, Object?> response, {
    required String key,
    required String id,
    int notBefore = 0,
  }) {
    final payload = response['payload'];
    final sig = response['sig'];
    if (payload is! String || sig is! String) return null;
    if (!_valid(_decode(key), utf8.encode(payload), _decode(sig))) return null;
    final Map<String, Object?> update;
    try {
      update = jsonDecode(payload) as Map<String, Object?>;
    } on FormatException {
      return null;
    }
    final ts = update['ts'];
    final urls = update['urls'];
    if (update['id'] != id || ts is! int || ts < notBefore || urls is! List) {
      return null;
    }
    return DirectoryRecord._([
      for (final url in urls)
        if (url is String && url.startsWith('https://')) url,
    ], ts);
  }

  static Uint8List _decode(String text) =>
      base64Url.decode(base64Url.normalize(text));

  /// ECDSA P-256 with SHA-256, signature as raw r‖s (64 bytes).
  static bool _valid(Uint8List key, List<int> data, Uint8List sig) {
    if (sig.length != 64 || key.length != 65) return false;
    try {
      final curve = ECCurve_secp256r1();
      final point = curve.curve.decodePoint(key);
      if (point == null) return false;
      BigInt number(List<int> bytes) => bytes.fold(
        BigInt.zero,
        (n, b) => (n << 8) | BigInt.from(b),
      );
      final signer = ECDSASigner(SHA256Digest())
        ..init(false, PublicKeyParameter(ECPublicKey(point, curve)));
      return signer.verifySignature(
        Uint8List.fromList(data),
        ECSignature(number(sig.sublist(0, 32)), number(sig.sublist(32))),
      );
    } catch (_) {
      return false;
    }
  }
}
