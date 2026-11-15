import 'dart:io';

import 'package:basic_utils/basic_utils.dart';
import 'package:crypto/crypto.dart';

/// The server's own HTTPS certificate for remote access.
///
/// It's self-signed, so instead of trusting a certificate authority, devices
/// "pin" its fingerprint: they learn it when they sign in (QR code, or at
/// home) and afterwards accept only this exact certificate.
class ServerCertificate {
  final String certPem;
  final String keyPem;

  /// SHA-256 of the certificate, hex, e.g. "3F:A2:…".
  final String fingerprint;

  ServerCertificate(this.certPem, this.keyPem)
    : fingerprint = fingerprintOf(CryptoUtils.getBytesFromPEMString(certPem));

  /// Loads the certificate from [dir], creating it on first run.
  static ServerCertificate loadOrCreate(Directory dir) {
    final certFile = File('${dir.path}/remote-cert.pem');
    final keyFile = File('${dir.path}/remote-key.pem');
    if (certFile.existsSync() && keyFile.existsSync()) {
      return ServerCertificate(
        certFile.readAsStringSync(),
        keyFile.readAsStringSync(),
      );
    }
    final pair = CryptoUtils.generateEcKeyPair();
    final privateKey = pair.privateKey as ECPrivateKey;
    final csr = X509Utils.generateEccCsrPem(
      {'CN': 'OpenHabits server'},
      privateKey,
      pair.publicKey as ECPublicKey,
    );
    final certPem = X509Utils.generateSelfSignedCertificate(
      privateKey,
      csr,
      3650,
      sans: ['localhost'],
      serialNumber: '${DateTime.now().millisecondsSinceEpoch}',
    );
    final keyPem = CryptoUtils.encodeEcPrivateKeyToPem(privateKey);
    dir.createSync(recursive: true);
    keyFile.writeAsStringSync(keyPem);
    certFile.writeAsStringSync(certPem);
    // The key is protected by the data folder's permissions (it's private
    // to the app's user); the minimal container has no chmod to tighten it.
    return ServerCertificate(certPem, keyPem);
  }

  SecurityContext get securityContext => SecurityContext()
    ..useCertificateChainBytes(certPem.codeUnits)
    ..usePrivateKeyBytes(keyPem.codeUnits);
}

/// The fingerprint format shared with the app: uppercase hex pairs joined by
/// colons, as most tools display it.
String fingerprintOf(List<int> der) => sha256
    .convert(der)
    .bytes
    .map((b) => b.toRadixString(16).padLeft(2, '0').toUpperCase())
    .join(':');
