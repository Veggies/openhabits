import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:xml/xml.dart';

/// A home router that accepts UPnP port-mapping requests.
class UpnpGateway {
  final Uri controlUrl;
  final String serviceType;

  /// This machine's address as the router sees it, i.e. where forwarded
  /// traffic should go.
  final String localAddress;

  UpnpGateway(this.controlUrl, this.serviceType, this.localAddress);
}

class UpnpException implements Exception {
  final String message;
  const UpnpException(this.message);

  @override
  String toString() => message;
}

/// Asks the home router to forward a port, the way Plex's "Enable remote
/// access" does. Uses UPnP Internet Gateway Device, which most home routers
/// support (sometimes switched off in their settings).
class UpnpClient {
  final http.Client _http;
  UpnpClient({http.Client? client}) : _http = client ?? http.Client();

  static const _searchTargets = [
    'urn:schemas-upnp-org:device:InternetGatewayDevice:1',
    'urn:schemas-upnp-org:device:InternetGatewayDevice:2',
  ];

  /// Finds the router, or returns null if none answers. Needs to share the
  /// router's network: in Docker that means host networking.
  Future<UpnpGateway?> discover({
    Duration timeout = const Duration(seconds: 3),
  }) async {
    final socket = await RawDatagramSocket.bind(InternetAddress.anyIPv4, 0);
    final locations = <Uri>{};
    final done = Completer<void>();
    final timer = Timer(timeout, () {
      if (!done.isCompleted) done.complete();
    });
    socket.listen((event) {
      if (event != RawSocketEvent.read) return;
      final datagram = socket.receive();
      if (datagram == null) return;
      final match = RegExp(
        r'^location:\s*(\S+)',
        caseSensitive: false,
        multiLine: true,
      ).firstMatch(utf8.decode(datagram.data, allowMalformed: true));
      final url = match == null ? null : Uri.tryParse(match[1]!);
      if (url != null) {
        locations.add(url);
        // Give other devices a moment to answer, then stop early.
        Timer(const Duration(milliseconds: 300), () {
          if (!done.isCompleted) done.complete();
        });
      }
    });
    for (final target in _searchTargets) {
      final message =
          'M-SEARCH * HTTP/1.1\r\n'
          'HOST: 239.255.255.250:1900\r\n'
          'MAN: "ssdp:discover"\r\n'
          'MX: 2\r\n'
          'ST: $target\r\n\r\n';
      socket.send(
        utf8.encode(message),
        InternetAddress('239.255.255.250'),
        1900,
      );
    }
    await done.future;
    timer.cancel();
    socket.close();

    for (final location in locations) {
      try {
        final gateway = await _describe(location);
        if (gateway != null) return gateway;
      } catch (_) {
        // Try the next device that answered.
      }
    }
    return null;
  }

  Future<UpnpGateway?> _describe(Uri location) async {
    final response = await _http
        .get(location)
        .timeout(const Duration(seconds: 5));
    final xml = XmlDocument.parse(response.body);
    final base = xml.descendants
        .whereType<XmlElement>()
        .where((e) => e.name.local == 'URLBase')
        .firstOrNull
        ?.innerText
        .trim();
    final baseUrl = base == null || base.isEmpty ? location : Uri.parse(base);
    for (final service in xml.descendants.whereType<XmlElement>().where(
      (e) => e.name.local == 'service',
    )) {
      String? child(String name) => service.childElements
          .where((e) => e.name.local == name)
          .firstOrNull
          ?.innerText
          .trim();
      final type = child('serviceType') ?? '';
      final control = child('controlURL');
      if (control != null &&
          (type.contains('WANIPConnection') ||
              type.contains('WANPPPConnection'))) {
        final local = await _localAddressFor(location);
        return UpnpGateway(baseUrl.resolve(control), type, local);
      }
    }
    return null;
  }

  /// The local address used to reach the router: connect and look.
  Future<String> _localAddressFor(Uri location) async {
    final socket = await Socket.connect(
      location.host,
      location.port,
      timeout: const Duration(seconds: 3),
    );
    final address = socket.address.address;
    socket.destroy();
    return address;
  }

  Future<XmlDocument> _soap(
    UpnpGateway gw,
    String action,
    Map<String, Object> args,
  ) async {
    final body =
        '<?xml version="1.0"?>'
        '<s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/" '
        's:encodingStyle="http://schemas.xmlsoap.org/soap/encoding/"><s:Body>'
        '<u:$action xmlns:u="${gw.serviceType}">'
        '${args.entries.map((e) => '<${e.key}>${const HtmlEscape().convert('${e.value}')}</${e.key}>').join()}'
        '</u:$action></s:Body></s:Envelope>';
    final response = await _http
        .post(
          gw.controlUrl,
          headers: {
            'content-type': 'text/xml; charset="utf-8"',
            'SOAPAction': '"${gw.serviceType}#$action"',
          },
          body: body,
        )
        .timeout(const Duration(seconds: 5));
    final xml = XmlDocument.parse(response.body);
    if (response.statusCode != 200) {
      final code = xml.descendants
          .whereType<XmlElement>()
          .where((e) => e.name.local == 'errorCode')
          .firstOrNull
          ?.innerText;
      final description = xml.descendants
          .whereType<XmlElement>()
          .where((e) => e.name.local == 'errorDescription')
          .firstOrNull
          ?.innerText;
      throw UpnpException(
        'Router refused $action (${code ?? response.statusCode}${description == null ? '' : ': $description'})',
      );
    }
    return xml;
  }

  /// The router's internet-facing address.
  Future<String> externalAddress(UpnpGateway gw) async {
    final xml = await _soap(gw, 'GetExternalIPAddress', const {});
    final ip = xml.descendants
        .whereType<XmlElement>()
        .where((e) => e.name.local == 'NewExternalIPAddress')
        .firstOrNull;
    if (ip == null || ip.innerText.trim().isEmpty) {
      throw const UpnpException(
        "The router didn't report its internet address.",
      );
    }
    return ip.innerText.trim();
  }

  /// Forwards [externalPort] on the router to [internalPort] on this machine.
  Future<void> addPortMapping(
    UpnpGateway gw, {
    required int externalPort,
    required int internalPort,
    String description = 'Tasks server',
    int leaseSeconds = 3600,
  }) async {
    Map<String, Object> args(int lease) => {
      'NewRemoteHost': '',
      'NewExternalPort': externalPort,
      'NewProtocol': 'TCP',
      'NewInternalPort': internalPort,
      'NewInternalClient': gw.localAddress,
      'NewEnabled': 1,
      'NewPortMappingDescription': description,
      'NewLeaseDuration': lease,
    };
    try {
      await _soap(gw, 'AddPortMapping', args(leaseSeconds));
    } on UpnpException catch (e) {
      // Error 725: this router only supports permanent mappings.
      if (!e.message.contains('725')) rethrow;
      await _soap(gw, 'AddPortMapping', args(0));
    }
  }

  Future<void> deletePortMapping(UpnpGateway gw, int externalPort) =>
      _soap(gw, 'DeletePortMapping', {
        'NewRemoteHost': '',
        'NewExternalPort': externalPort,
        'NewProtocol': 'TCP',
      });
}
