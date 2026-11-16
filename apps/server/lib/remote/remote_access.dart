import 'dart:async';
import 'dart:io';

import 'package:http/http.dart' as http;

import '../settings_store.dart';
import 'directory.dart';
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

  /// Where devices look this server up when its address changes (null when
  /// the directory is turned off).
  final DirectoryClient? directory;
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
    this.directory,
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
    status = RemoteStatus(RemoteState.off, 'Remote access is off.');
    await _publish();
    return status;
  }

  Future<RemoteStatus> refresh() async {
    try {
      status = await _check();
      if (status.state == RemoteState.on) settings.lastRemoteUrl = status.url;
      if (status.state == RemoteState.off) settings.lastRemoteUrl = null;
      await _publish();
      return status;
    } catch (e) {
      return status = RemoteStatus(
        RemoteState.error,
        'Something went wrong: $e',
      );
    }
  }

  /// Asks the router to forward [preferred], or the next free port if that
  /// one is already forwarded somewhere else (UPnP error 718). Many routers
  /// keep 8443 for their own admin page, or the user has a rule for it. The
  /// port that worked is saved, so renewals and devices keep using it.
  Future<int> _mapFreePort(UpnpGateway gw, int preferred) async {
    final candidates = [
      preferred,
      for (var i = 1; i <= 5; i++) 40000 + (preferred + i * 1009) % 20000,
    ];
    for (final port in candidates) {
      try {
        await _upnp.addPortMapping(
          gw,
          externalPort: port,
          internalPort: httpsPort,
        );
        if (port != preferred) settings.remotePort = port;
        return port;
      } on UpnpException catch (e) {
        if (e.code != 718) rethrow;
      }
    }
    throw UpnpException(
      'Your router says the ports OpenHabits tried (${candidates.join(', ')}) '
      'are all forwarded to something else already. Pick a different port '
      "under \"Port\", or remove the old forwarding rule in your router's settings.",
      code: 718,
    );
  }

  /// Keeps the directory's entry for this server current. Only a working
  /// address is published, and only "off" removes it: a router that briefly
  /// doesn't answer shouldn't make devices forget where home is.
  Future<void> _publish() async {
    final directory = this.directory;
    if (directory == null) return;
    final List<String> urls;
    if (status.state == RemoteState.on && status.url != null) {
      urls = [status.url!];
    } else if (status.state == RemoteState.off) {
      urls = const [];
    } else {
      return;
    }
    final last = settings.directoryPublished;
    final now = DateTime.now();
    final same =
        last != null &&
        last.urls.join(' ') == urls.join(' ') &&
        (urls.isEmpty || now.difference(last.at) < const Duration(days: 3));
    if (same || (last == null && urls.isEmpty)) return;
    try {
      await directory.publish(urls);
      settings.directoryPublished = (urls: urls, at: now);
    } catch (e) {
      // Tried again at the next check, in 15 minutes.
      stderr.writeln("Couldn't update the OpenHabits directory: $e");
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
        'Devices away from home connect through your reverse proxy or relay.',
        url: override,
      );
    }

    var port = settings.remotePort;
    final gw = await _upnp.discover();

    if (gw == null) {
      final publicIp = await _publicIp();
      if (settings.remoteManual && publicIp != null) {
        return _reachableAt(publicIp, port);
      }
      return RemoteStatus(
        RemoteState.needsPortForward,
        "Your router didn't answer the automatic request (UPnP). Turn on UPnP in "
        'its settings and check again, or forward the port yourself (steps below). '
        'In Docker, this needs host networking.',
        publicIp: publicIp,
      );
    }

    port = await _mapFreePort(gw, port);
    final routerIp = await _upnp.externalAddress(gw);
    final publicIp = await _publicIp();

    // The router's "internet" address is itself private, or doesn't match
    // the address the world sees: the provider is sharing one address.
    if (isPrivateAddress(routerIp) ||
        (publicIp != null && publicIp != routerIp)) {
      return RemoteStatus(
        RemoteState.cgnat,
        'Your internet provider shares one address between many homes (CGNAT), '
        "so nothing outside can connect in directly. Use a relay instead (steps "
        'below).',
        publicIp: publicIp ?? routerIp,
        localAddress: gw.localAddress,
      );
    }

    return _reachableAt(routerIp, port, localAddress: gw.localAddress);
  }

  /// Remote access works: devices get the home's internet address, and the
  /// directory keeps them up to date if it changes.
  RemoteStatus _reachableAt(String homeIp, int port, {String? localAddress}) =>
      RemoteStatus(
        RemoteState.on,
        'Your devices can reach this server from anywhere.',
        url: 'https://$homeIp:$port',
        publicIp: homeIp,
        localAddress: localAddress,
      );

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
