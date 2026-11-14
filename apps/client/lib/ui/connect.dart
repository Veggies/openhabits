import 'package:flutter/foundation.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../data/sync_engine.dart';
import 'common.dart';

/// Phones can scan pairing QR codes; computers type the code instead.
bool get canScanQr =>
    !kIsWeb &&
    (defaultTargetPlatform == TargetPlatform.iOS ||
        defaultTargetPlatform == TargetPlatform.android);

/// The text inside a pairing QR code. Besides the one-time code it carries
/// the server's remote address and certificate fingerprint, so a phone
/// paired at home also works away from home. The server's setup page makes
/// the same format.
String pairingPayload(
  String serverUrl,
  String code, {
  String? remoteUrl,
  String? fingerprint,
}) => Uri(
  scheme: 'tasks',
  host: 'pair',
  queryParameters: {
    'server': serverUrl,
    'code': code,
    'remote': ?remoteUrl,
    'fp': ?fingerprint,
  },
).toString();

typedef Pairing = ({
  String server,
  String code,
  String? remote,
  String? fingerprint,
});

Pairing? parsePairingPayload(String text) {
  final uri = Uri.tryParse(text);
  final q = uri?.queryParameters ?? const {};
  final server = q['server'];
  final code = q['code'];
  if (uri?.scheme != 'tasks' ||
      uri?.host != 'pair' ||
      server == null ||
      code == null) {
    return null;
  }
  return (
    server: server,
    code: code,
    remote: q['remote'],
    fingerprint: q['fp'],
  );
}

/// Connects this device to a server: address first, then any sign-in
/// method the server offers. Calls [onSignedIn] when done.
class ConnectForm extends StatefulWidget {
  final ValueChanged<Account> onSignedIn;
  const ConnectForm({super.key, required this.onSignedIn});

  @override
  State<ConnectForm> createState() => _ConnectFormState();
}

class _ConnectFormState extends State<ConnectForm> {
  late final _address = TextEditingController(
    text: AppScope.read(context).sync.serverUrl ?? '',
  );
  final _username = TextEditingController();
  final _password = TextEditingController();
  final _code = TextEditingController();
  ServerInfo? server;
  bool busy = false;
  bool useCode = false;
  String? error;

  @override
  void dispose() {
    for (final c in [_address, _username, _password, _code]) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _run(Future<void> Function() action) async {
    setState(() {
      busy = true;
      error = null;
    });
    try {
      await action();
    } catch (e) {
      if (mounted) setState(() => error = '$e');
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  SyncEngine get _sync => AppScope.read(context).sync;

  Future<void> _lookUp() => _run(() async {
    try {
      final info = await _sync.serverInfo(_address.text);
      setState(() => server = info);
    } on UntrustedServerException catch (e) {
      // The server's own remote-access certificate: ask the person to
      // compare its security code with the one on the setup page.
      if (!mounted || !await _confirmCertificate(e)) return;
      _sync.trustCertificate(e.fingerprint);
      final info = await _sync.serverInfo(e.url);
      setState(() => server = info);
    }
  });

  Future<bool> _confirmCertificate(UntrustedServerException e) async =>
      await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('Check the security code'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                "On your server's setup page, under Remote access, find the security code. "
                'Make sure it matches this one:',
              ),
              const SizedBox(height: 12),
              SelectableText(
                e.shortCode,
                style: const TextStyle(fontFamily: 'monospace', fontSize: 16),
              ),
              const SizedBox(height: 12),
              const Text(
                "If it doesn't match, don't continue: you may not be connected to your own server.",
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('It matches'),
            ),
          ],
        ),
      ) ??
      false;

  Future<void> _signIn() => _run(() async {
    widget.onSignedIn(
      await _sync.signIn(server!.url, _username.text.trim(), _password.text),
    );
  });

  Future<void> _redeem() => _run(() async {
    widget.onSignedIn(await _sync.redeemCode(server!.url, _code.text));
  });

  Future<void> _sso() => _run(() async {
    widget.onSignedIn(await _sync.signInWithOidc(server!.url));
  });

  Future<void> _scan() async {
    final text = await Navigator.of(context)
        .push<String>(MaterialPageRoute(builder: (_) => const _ScannerPage()));
    final pairing = text == null ? null : parsePairingPayload(text);
    if (text != null && pairing == null) {
      setState(() => error = "That QR code isn't a Tasks pairing code.");
      return;
    }
    if (pairing == null) return;
    await _run(() async {
      _address.text = pairing.server;
      widget.onSignedIn(
        await _sync.redeemCode(
          SyncEngine.normalizeUrl(pairing.server),
          pairing.code,
          remoteUrl: pairing.remote,
          fingerprint: pairing.fingerprint,
        ),
      );
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final info = server;
    return AutofillGroup(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          if (canScanQr && info == null) ...[
            FilledButton.icon(
              icon: const Icon(Icons.qr_code_scanner),
              label: const Text('Scan QR code from another device'),
              style: FilledButton.styleFrom(
                minimumSize: const Size.fromHeight(48),
              ),
              onPressed: busy ? null : _scan,
            ),
            const SizedBox(height: 16),
            Row(
              children: [
                const Expanded(child: Divider()),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  child: Text(
                    'or',
                    style: TextStyle(color: theme.colorScheme.outline),
                  ),
                ),
                const Expanded(child: Divider()),
              ],
            ),
            const SizedBox(height: 16),
          ],
          TextField(
            controller: _address,
            enabled: !busy,
            keyboardType: TextInputType.url,
            autocorrect: false,
            readOnly: info != null,
            decoration: InputDecoration(
              labelText: 'Server address',
              hintText: 'tasks.example.com or 192.168.1.10:8080',
              border: const OutlineInputBorder(),
              suffixIcon: info == null
                  ? null
                  : IconButton(
                      tooltip: 'Change server',
                      icon: const Icon(Icons.edit),
                      onPressed: () => setState(() => server = null),
                    ),
            ),
            onSubmitted: (_) => _lookUp(),
          ),
          const SizedBox(height: 12),
          if (info == null)
            FilledButton(
              onPressed: busy ? null : _lookUp,
              style: FilledButton.styleFrom(
                minimumSize: const Size.fromHeight(44),
              ),
              child: const Text('Continue'),
            )
          else ...[
            Text('Sign in to ${info.name}', style: theme.textTheme.titleMedium),
            const SizedBox(height: 12),
            if (!useCode) ...[
              TextField(
                controller: _username,
                enabled: !busy,
                autocorrect: false,
                autofillHints: const [AutofillHints.username],
                decoration: const InputDecoration(
                  labelText: 'Username',
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _password,
                enabled: !busy,
                obscureText: true,
                autofillHints: const [AutofillHints.password],
                decoration: const InputDecoration(
                  labelText: 'Password',
                  border: OutlineInputBorder(),
                ),
                onSubmitted: (_) => _signIn(),
              ),
              const SizedBox(height: 12),
              FilledButton(
                onPressed: busy ? null : _signIn,
                style: FilledButton.styleFrom(
                  minimumSize: const Size.fromHeight(44),
                ),
                child: const Text('Sign in'),
              ),
            ] else ...[
              TextField(
                controller: _code,
                enabled: !busy,
                autocorrect: false,
                textCapitalization: TextCapitalization.characters,
                decoration: const InputDecoration(
                  labelText: 'Pairing code',
                  hintText: 'ABCD-1234',
                  helperText: 'On a signed-in device: Settings → Add a device',
                  border: OutlineInputBorder(),
                ),
                onSubmitted: (_) => _redeem(),
              ),
              const SizedBox(height: 12),
              FilledButton(
                onPressed: busy ? null : _redeem,
                style: FilledButton.styleFrom(
                  minimumSize: const Size.fromHeight(44),
                ),
                child: const Text('Connect'),
              ),
            ],
            if (info.oidcLabel != null) ...[
              const SizedBox(height: 12),
              OutlinedButton.icon(
                icon: const Icon(Icons.login),
                label: Text('Sign in with ${info.oidcLabel}'),
                style: OutlinedButton.styleFrom(
                  minimumSize: const Size.fromHeight(44),
                ),
                onPressed: busy ? null : _sso,
              ),
            ],
            TextButton(
              onPressed: busy ? null : () => setState(() => useCode = !useCode),
              child: Text(
                useCode
                    ? 'Use username and password instead'
                    : 'Have a code from another device?',
              ),
            ),
          ],
          if (busy)
            const Padding(
              padding: EdgeInsets.only(top: 12),
              child: LinearProgressIndicator(),
            ),
          if (error != null)
            Padding(
              padding: const EdgeInsets.only(top: 12),
              child: Text(
                error!,
                style: TextStyle(color: theme.colorScheme.error),
              ),
            ),
        ],
      ),
    );
  }
}

class _ScannerPage extends StatefulWidget {
  const _ScannerPage();

  @override
  State<_ScannerPage> createState() => _ScannerPageState();
}

class _ScannerPageState extends State<_ScannerPage> {
  bool done = false;

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Scan pairing code')),
    body: Stack(
      children: [
        MobileScanner(
          onDetect: (capture) {
            final value = capture.barcodes.firstOrNull?.rawValue;
            if (done || value == null) return;
            done = true;
            Navigator.pop(context, value);
          },
        ),
        Align(
          alignment: Alignment.bottomCenter,
          child: Container(
            margin: const EdgeInsets.all(24),
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: Colors.black54,
              borderRadius: BorderRadius.circular(12),
            ),
            child: const Text(
              'On a signed-in device, open Settings → Add a device',
              style: TextStyle(color: Colors.white),
            ),
          ),
        ),
      ],
    ),
  );
}

/// Shows a QR code and typed code that sign another device in as you.
Future<void> showAddDevice(BuildContext context) async {
  final sync = AppScope.of(context).sync;
  await showDialog<void>(
    context: context,
    builder: (context) => FutureBuilder(
      future: sync.pairingCode(),
      builder: (context, snapshot) {
        final theme = Theme.of(context);
        final data = snapshot.data;
        return AlertDialog(
          title: const Text('Add a device'),
          content: SizedBox(
            width: 320,
            child: snapshot.hasError
                ? Text('${snapshot.error}')
                : data == null
                ? const SizedBox(
                    height: 260,
                    child: Center(child: CircularProgressIndicator()),
                  )
                : Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Text(
                        'On your phone, open Tasks and scan this code:',
                      ),
                      const SizedBox(height: 12),
                      Container(
                        padding: const EdgeInsets.all(8),
                        color: Colors.white,
                        child: QrImageView(
                          data: pairingPayload(
                            data.url,
                            data.code,
                            remoteUrl: data.remoteUrl,
                            fingerprint: data.fingerprint,
                          ),
                          size: 220,
                        ),
                      ),
                      const SizedBox(height: 16),
                      const Text(
                        'On a computer, enter the server address and this code:',
                      ),
                      const SizedBox(height: 8),
                      SelectableText(
                        data.url,
                        style: theme.textTheme.bodySmall,
                      ),
                      SelectableText(
                        data.code,
                        style: theme.textTheme.headlineSmall?.copyWith(
                          letterSpacing: 2,
                          fontFamily: 'monospace',
                        ),
                      ),
                      const SizedBox(height: 8),
                      Text(
                        'This code works once and expires in 10 minutes.',
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.outline,
                        ),
                      ),
                    ],
                  ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Done'),
            ),
          ],
        );
      },
    ),
  );
}
