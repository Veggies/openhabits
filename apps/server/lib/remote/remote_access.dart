import 'dart:async';
import 'dart:io';

import 'package:http/http.dart' as http;

import '../settings_store.dart';
import 'upnp.dart';

enum RemoteState {
  /// Remote access is turned off.
  off,

  /// Reachable from the internet.
  on,

  /// The router didn't answer the automatic request; forward the port by hand.
  needsPortForward,

  /// The internet provider shares one address between customers, so nothing
  /// outside can connect in. A relay (e.g. Tailscale Funnel) is needed.
  cgnat,

  /// Something else went wrong; see the message.
  error,
}

class RemoteStatus {
  final RemoteState state;
  final String? url;
  final String? publicIp;
  final String? localAddress;
  final String message;
  final DateTime checkedAt;

  RemoteStatus(
    this.state,
    this.message, {
    this.url,
    this.publicIp,
    this.localAddress,
  }) : checkedAt = DateTime.now();

  Map<String, Object?> toJson() => {
    'state': state.name,
    'url': url,
    'publicIp': publicIp,
    'localAddress': localAddress,
    'message': message,
    'checkedAt': checkedAt.toUtc().toIso8601String(),
  };
}

/// Addresses that can't be reached from the internet. 100.64.0.0/10 is the
/// range internet providers use for CGNAT.
bool isPrivateAddress(String ip) {
  final parts = ip.split('.').map(int.tryParse).toList();
  if (parts.length != 4 || parts.any((p) => p == null)) return false;
  final a = parts[0]!, b = parts[1]!;
  return a == 10 ||
      a == 127 ||
      (a == 172 && b >= 16 && b <= 31) ||
      (a == 192 && b == 168) ||
      (a == 169 && b == 254) ||
      (a == 100 && b >= 64 && b <= 127);
}

typedef PublicIpLookup = Future<String?> Function();

/// Makes the server reachable from anywhere, the way Plex's "Enable remote
/// access" does: ask the router to forward a port, and check that the
/// router really has its own internet address.
class RemoteAccess {
  final SettingsStore settings;

  /// The port the HTTPS server listens on inside this machine/container.
  final int httpsPort;
  final UpnpClient _upnp;
  final PublicIpLookup _publicIp;
  Timer? _renew;

  late RemoteStatus status =
      settings.remoteEnabled && settings.lastRemoteUrl != null
      // After a restart, keep offering the last working address while the
      // router is checked again, so devices away from home don't lose it.
      ? RemoteStatus(
          RemoteState.on,
          'Checking with your router…',
          url: settings.lastRemoteUrl,
        )
      : RemoteStatus(RemoteState.off, 'Remote access is off.');

  RemoteAccess(
    this.settings, {
    required this.httpsPort,
    UpnpClient? upnp,
    PublicIpLookup? publicIp,
  }) : _upnp = upnp ?? UpnpClient(),
       _publicIp = publicIp ?? lookupPublicIp;

  /// The address devices should use when away from home, if any.
  String? get url => status.state == RemoteState.on ? status.url : null;

  /// Starts keeping the router mapping alive (leases expire), if enabled.
  void start() {
    _renew?.cancel();
    _renew = Timer.periodic(const Duration(minutes: 15), (_) => refresh());
    unawaited(refresh());
  }

  Future<RemoteStatus> enable({bool manual = false}) {
    settings.remoteEnabled = true;
    settings.remoteManual = manual;
    return refresh();
  }

  Future<RemoteStatus> disable() async {
    settings.remoteEnabled = false;
    try {
      final gw = await _upnp.discover();
      if (gw != null) await _upnp.deletePortMapping(gw, settings.remotePort);
    } catch (_) {
      // The mapping expires on its own.
    }
    return status = RemoteStatus(RemoteState.off, 'Remote access is off.');
  }

  Future<RemoteStatus> refresh() async {
    try {
      status = await _check();
      if (status.state == RemoteState.on) settings.lastRemoteUrl = status.url;
      if (status.state == RemoteState.off) settings.lastRemoteUrl = null;
      return status;
    } catch (e) {
      return status = RemoteStatus(
        RemoteState.error,
        'Something went wrong: $e',
      );
    }
  }

  Future<RemoteStatus> _check() async {
    if (!settings.remoteEnabled) {
      return RemoteStatus(RemoteState.off, 'Remote access is off.');
    }

    final override = settings.publicUrl;
    if (override != null) {
      return RemoteStatus(
        RemoteState.on,
        'Devices away from home will use your custom address.',
        url: override,
      );
    }

    final port = settings.remotePort;
    final gw = await _upnp.discover();

    if (gw == null) {
      final publicIp = await _publicIp();
      if (settings.remoteManual && publicIp != null) {
        return RemoteStatus(
          RemoteState.on,
          "Using the port you forwarded on your router. If devices can't connect from outside, "
          'check that the forward points to this server on port $port.',
          url: 'https://$publicIp:$port',
          publicIp: publicIp,
        );
      }
      return RemoteStatus(
        RemoteState.needsPortForward,
        "Your router didn't respond to the automatic request. Either turn on UPnP in your "
        "router's settings and try again, or forward TCP port $port on your router to this "
        "server's port $httpsPort yourself, then choose \"I've forwarded the port\". "
        "(Running in Docker? The app needs host networking for automatic setup.)",
        publicIp: publicIp,
      );
    }

    await _upnp.addPortMapping(gw, externalPort: port, internalPort: httpsPort);
    final routerIp = await _upnp.externalAddress(gw);
    final publicIp = await _publicIp();

    // The router's "internet" address is itself private, or doesn't match
    // the address the world sees: the provider is sharing one address.
    if (isPrivateAddress(routerIp) ||
        (publicIp != null && publicIp != routerIp)) {
      return RemoteStatus(
        RemoteState.cgnat,
        "Your internet provider shares one internet address between many customers "
        "(this is called CGNAT), so devices outside your home can't connect to this "
        'server directly, no matter what your router does. You can still use it '
        'everywhere through a relay. See the steps below.',
        publicIp: publicIp ?? routerIp,
        localAddress: gw.localAddress,
      );
    }

    return RemoteStatus(
      RemoteState.on,
      "Your devices can reach this server from anywhere. To double-check, open the app on "
      'your phone using mobile data instead of Wi-Fi.',
      url: 'https://$routerIp:$port',
      publicIp: routerIp,
      localAddress: gw.localAddress,
    );
  }

  void dispose() => _renew?.cancel();
}

/// This network's address as seen from the internet.
Future<String?> lookupPublicIp() async {
  for (final service in ['https://api.ipify.org', 'https://ifconfig.me/ip']) {
    try {
      final response = await http
          .get(Uri.parse(service))
          .timeout(const Duration(seconds: 5));
      final ip = response.body.trim();
      if (response.statusCode == 200 && InternetAddress.tryParse(ip) != null) {
        return ip;
      }
    } catch (_) {
      // Try the next one.
    }
  }
  return null;
}
