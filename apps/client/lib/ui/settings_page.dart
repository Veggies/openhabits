import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';

import 'package:url_launcher/url_launcher.dart';

import '../data/sync_engine.dart';
import 'common.dart';
import 'connect.dart';
import 'onboarding.dart';

class SettingsPage extends StatefulWidget {
  const SettingsPage({super.key});

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  @override
  Widget build(BuildContext context) {
    final scope = AppScope.of(context);
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(title: const Text('Settings')),
      body: ListenableBuilder(
        listenable: Listenable.merge([scope.sync, scope.repo.store]),
        builder: (context, _) {
          final sync = scope.sync;
          final repo = scope.repo;
          final account = sync.account;
          final signedIn = sync.isConfigured && account != null;

          Widget section(String title) => Padding(
            padding: const EdgeInsets.fromLTRB(4, 28, 4, 8),
            child: Text(title, style: theme.textTheme.titleMedium),
          );

          return CenteredListView(
            maxWidth: 560,
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 40),
            children: [
              section('Account'),
              if (signedIn) ...[
                Card(
                  child: Column(
                    children: [
                      ListTile(
                        leading: CircleAvatar(
                          child: Text(
                            account.username.substring(0, 1).toUpperCase(),
                          ),
                        ),
                        title: Text(account.username),
                        subtitle: Text(
                          '${sync.serverUrl}${account.isOwner ? ' · Owner' : ''}',
                        ),
                        trailing: _StatusIcon(sync: sync),
                      ),
                      if (sync.status == SyncStatus.error &&
                          sync.lastError != null)
                        Padding(
                          padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
                          child: Text(
                            sync.lastError!,
                            style: TextStyle(color: theme.colorScheme.error),
                          ),
                        ),
                      const Divider(height: 1),
                      ListTile(
                        leading: const Icon(Icons.qr_code_2),
                        title: const Text('Add a device'),
                        subtitle: const Text(
                          'Show a QR code to sign in your phone or another computer',
                        ),
                        onTap: () => showAddDevice(context),
                      ),
                      ListTile(
                        leading: const Icon(Icons.password),
                        title: const Text('Change password'),
                        onTap: () => _changePassword(context, sync),
                      ),
                      ListTile(
                        leading: const Icon(Icons.alternate_email),
                        title: const Text('Email for single sign-on'),
                        subtitle: Text(account.email ?? 'Not set'),
                        onTap: () async {
                          final email = await promptText(
                            context,
                            title: 'Email',
                            initial: account.email ?? '',
                            hint: 'you@gmail.com',
                          );
                          if (email != null && context.mounted) {
                            await _guard(
                              context,
                              () => sync.setEmail(email.trim()),
                            );
                          }
                        },
                      ),
                      if (account.isOwner)
                        ListTile(
                          leading: const Icon(Icons.dns_outlined),
                          title: const Text('Server settings'),
                          subtitle: const Text(
                            'Remote access, people and sign-in options',
                          ),
                          trailing: const Icon(Icons.open_in_new, size: 18),
                          onTap: () => launchUrl(Uri.parse(sync.setupPageUrl!)),
                        ),
                      ListTile(
                        leading: const Icon(Icons.logout),
                        title: const Text('Sign out'),
                        onTap: () => sync.signOut(),
                      ),
                    ],
                  ),
                ),
                Text(
                  '${repo.store.pendingCount} change(s) waiting to upload',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.outline,
                  ),
                ),
              ] else
                Card(
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          sync.status == SyncStatus.signedOut
                              ? 'You were signed out. Sign in again to keep syncing.'
                              : "Everything works on this device as it is. If you'd like your other devices to stay in sync, connect to your server.",
                        ),
                        const SizedBox(height: 16),
                        ConnectForm(onSignedIn: (_) {}),
                      ],
                    ),
                  ),
                ),
              if (signedIn && account.isOwner) ...[
                section('People'),
                const _People(),
              ],
              section('Habits'),
              Card(
                child: Column(
                  children: [
                    SwitchListTile(
                      title: const Text('Use the Atomic Habits framework'),
                      subtitle: const Text(
                        'Adds ideas from the book Atomic Habits: tiny starter versions, rewards, '
                        'streaks that forgive one missed day, a scorecard and a weekly review.',
                      ),
                      value: repo.atomicHabits,
                      onChanged: (v) => repo.setPrefs({'atomicHabits': v}),
                    ),
                    ListTile(
                      title: const Text('Week starts on'),
                      trailing: SegmentedButton<int>(
                        showSelectedIcon: false,
                        segments: const [
                          ButtonSegment(
                            value: DateTime.sunday,
                            label: Text('Sunday'),
                          ),
                          ButtonSegment(
                            value: DateTime.monday,
                            label: Text('Monday'),
                          ),
                        ],
                        selected: {repo.weekStart},
                        onSelectionChanged: (s) =>
                            repo.setPrefs({'weekStart': s.first}),
                      ),
                    ),
                    ListTile(
                      leading: const Icon(Icons.event_outlined),
                      title: const Text('Show habits in your calendar app'),
                      subtitle: Text(
                        signedIn
                            ? 'Habits with a time show up in Apple, Google or Outlook Calendar.'
                            : 'Connect to your server first, above.',
                      ),
                      enabled: signedIn,
                      onTap: () => showDialog<void>(
                        context: context,
                        builder: (_) => const _CalendarLinkDialog(),
                      ),
                    ),
                    ListTile(
                      leading: const Icon(Icons.replay),
                      title: const Text('Run setup again'),
                      subtitle: const Text(
                        'Go through the welcome steps again, including building a habit step by step.',
                      ),
                      onTap: () => Navigator.of(context).push(
                        MaterialPageRoute<void>(
                          fullscreenDialog: true,
                          builder: (route) => Onboarding(
                            replay: true,
                            onDone: () => Navigator.of(route).pop(),
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          );
        },
      ),
    );
  }

  Future<void> _changePassword(BuildContext context, SyncEngine sync) async {
    final current = TextEditingController();
    final next = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Change password'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: current,
              obscureText: true,
              decoration: const InputDecoration(labelText: 'Current password'),
            ),
            TextField(
              controller: next,
              obscureText: true,
              decoration: const InputDecoration(
                labelText: 'New password',
                helperText: 'At least 8 characters',
              ),
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
            child: const Text('Change'),
          ),
        ],
      ),
    );
    if (ok == true && context.mounted) {
      await _guard(
        context,
        () => sync.changePassword(current.text, next.text),
        success: 'Password changed.',
      );
    }
  }
}

/// Runs [action], showing its error (or [success]) in a snackbar.
Future<void> _guard(
  BuildContext context,
  Future<void> Function() action, {
  String? success,
}) async {
  final messenger = ScaffoldMessenger.of(context);
  try {
    await action();
    if (success != null) {
      messenger.showSnackBar(SnackBar(content: Text(success)));
    }
  } catch (e) {
    messenger.showSnackBar(SnackBar(content: Text('$e')));
  }
}

class _StatusIcon extends StatelessWidget {
  final SyncEngine sync;
  const _StatusIcon({required this.sync});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final (icon, color, tip) = switch (sync.status) {
      SyncStatus.syncing => (Icons.cloud_sync, scheme.primary, 'Syncing…'),
      SyncStatus.idle => (
        Icons.cloud_done,
        Colors.green,
        sync.lastSynced == null
            ? 'Connected'
            : 'Synced at ${clockLabel(context, sync.lastSynced!)}',
      ),
      SyncStatus.error => (
        Icons.cloud_off,
        scheme.error,
        sync.lastError ?? 'Sync failed',
      ),
      SyncStatus.notConfigured || SyncStatus.signedOut => (
        Icons.cloud_off,
        scheme.outline,
        'Not connected',
      ),
    };
    return IconButton(
      tooltip: tip,
      icon: Icon(icon, color: color),
      onPressed: sync.syncNow,
    );
  }
}

/// The owner's household list: add and remove people.
class _People extends StatefulWidget {
  const _People();

  @override
  State<_People> createState() => _PeopleState();
}

class _PeopleState extends State<_People> {
  late Future<List<Account>> _people = AppScope.read(context).sync.people();

  void _reload() =>
      setState(() => _people = AppScope.read(context).sync.people());

  @override
  Widget build(BuildContext context) {
    final sync = AppScope.of(context).sync;
    return Card(
      child: FutureBuilder(
        future: _people,
        builder: (context, snapshot) => Column(
          children: [
            if (snapshot.hasError)
              ListTile(title: Text('${snapshot.error}'))
            else if (!snapshot.hasData)
              const Padding(
                padding: EdgeInsets.all(16),
                child: LinearProgressIndicator(),
              )
            else
              for (final p in snapshot.data!)
                ListTile(
                  leading: const Icon(Icons.person_outline),
                  title: Text(p.username),
                  subtitle: Text(
                    [if (p.isOwner) 'Owner', ?p.email].join(' · '),
                  ),
                  trailing: p.isOwner
                      ? null
                      : IconButton(
                          tooltip: 'Remove ${p.username}',
                          icon: const Icon(Icons.person_remove_outlined),
                          onPressed: () async {
                            final confirmed = await showDialog<bool>(
                              context: context,
                              builder: (context) => AlertDialog(
                                title: Text('Remove ${p.username}?'),
                                content: const Text(
                                  "This deletes their account and everything they've saved on this server.",
                                ),
                                actions: [
                                  TextButton(
                                    onPressed: () =>
                                        Navigator.pop(context, false),
                                    child: const Text('Cancel'),
                                  ),
                                  FilledButton(
                                    onPressed: () =>
                                        Navigator.pop(context, true),
                                    child: const Text('Remove'),
                                  ),
                                ],
                              ),
                            );
                            if (confirmed == true && context.mounted) {
                              await _guard(
                                context,
                                () => sync.removePerson(p.id),
                              );
                              _reload();
                            }
                          },
                        ),
                ),
            ListTile(
              leading: const Icon(Icons.person_add_alt),
              title: const Text('Add a person'),
              subtitle: const Text('Everyone gets their own private habits'),
              onTap: () => _add(context, sync),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _add(BuildContext context, SyncEngine sync) async {
    final username = TextEditingController();
    final password = TextEditingController();
    final email = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Add a person'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: username,
              autocorrect: false,
              decoration: const InputDecoration(labelText: 'Username'),
            ),
            TextField(
              controller: password,
              obscureText: true,
              decoration: const InputDecoration(
                labelText: 'Password',
                helperText: 'At least 8 characters',
              ),
            ),
            TextField(
              controller: email,
              keyboardType: TextInputType.emailAddress,
              decoration: const InputDecoration(
                labelText: 'Email (optional)',
                helperText: 'Lets them use single sign-on',
              ),
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
            child: const Text('Add'),
          ),
        ],
      ),
    );
    if (ok == true && context.mounted) {
      await _guard(
        context,
        () => sync.addPerson(
          username.text.trim(),
          password.text,
          email.text.trim(),
        ),
        success: 'Added ${username.text.trim()}.',
      );
      _reload();
    }
  }
}

/// The private calendar link, with how to add it to each calendar app.
class _CalendarLinkDialog extends StatefulWidget {
  const _CalendarLinkDialog();

  @override
  State<_CalendarLinkDialog> createState() => _CalendarLinkDialogState();
}

class _CalendarLinkDialogState extends State<_CalendarLinkDialog> {
  late Future<({String url, bool anywhere})> _link = AppScope.read(context).sync
      .calendarLink();

  /// Apple's calendar apps open "webcal" links as a subscription.
  bool get _apple =>
      defaultTargetPlatform == TargetPlatform.macOS ||
      defaultTargetPlatform == TargetPlatform.iOS;

  Future<void> _replace() async {
    final sure = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Make a new link?'),
        content: const Text(
          'The current link will stop working, so any calendar using it will '
          'stop showing your habits until you add the new one.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Make a new link'),
          ),
        ],
      ),
    );
    if (sure != true || !mounted) return;
    setState(
      () => _link = AppScope.read(context).sync.calendarLink(replace: true),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final muted = theme.textTheme.bodySmall?.copyWith(
      color: theme.colorScheme.outline,
    );
    return AlertDialog(
      title: const Text('Show habits in your calendar app'),
      content: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 480),
        child: FutureBuilder(
          future: _link,
          builder: (context, snapshot) {
            if (snapshot.hasError) {
              return Text("Couldn't get your link: ${snapshot.error}");
            }
            final link = snapshot.data;
            if (link == null) {
              return const SizedBox(
                height: 80,
                child: Center(child: CircularProgressIndicator()),
              );
            }
            return SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    "Any habit with a time shows up in your calendar as a repeating "
                    "event, on the days it's scheduled. When you change a habit here, "
                    'your calendar catches up within an hour or so.',
                  ),
                  const SizedBox(height: 12),
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.all(10),
                    decoration: BoxDecoration(
                      color: theme.colorScheme.surfaceContainerHighest,
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: SelectableText(
                      link.url,
                      style: theme.textTheme.bodySmall,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      FilledButton.tonalIcon(
                        icon: const Icon(Icons.copy),
                        label: const Text('Copy link'),
                        onPressed: () async {
                          await Clipboard.setData(
                            ClipboardData(text: link.url),
                          );
                          if (context.mounted) {
                            ScaffoldMessenger.of(context).showSnackBar(
                              const SnackBar(content: Text('Link copied.')),
                            );
                          }
                        },
                      ),
                      if (_apple)
                        OutlinedButton.icon(
                          icon: const Icon(Icons.event),
                          label: const Text('Open in Calendar'),
                          onPressed: () => launchUrl(
                            Uri.parse(
                              link.url.replaceFirst(
                                RegExp('^https?'),
                                'webcal',
                              ),
                            ),
                          ),
                        ),
                    ],
                  ),
                  if (!link.anywhere) ...[
                    const SizedBox(height: 12),
                    Container(
                      padding: const EdgeInsets.all(10),
                      decoration: BoxDecoration(
                        color: Colors.amber.withValues(alpha: 0.18),
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: Text(
                        "Right now this link only works on your home network, so it won't "
                        "work in Google Calendar or when you're out. To fix that, give your "
                        "server a public address on its setup page, under Remote access → Advanced.",
                        style: theme.textTheme.bodySmall,
                      ),
                    ),
                  ],
                  const SizedBox(height: 16),
                  Text('How to add it', style: theme.textTheme.titleSmall),
                  const SizedBox(height: 4),
                  Text(
                    '• Apple Calendar: ${_apple ? 'click Open in Calendar, or ' : ''}'
                    'choose File → New Calendar Subscription and paste the link.\n'
                    '• Google Calendar: on the website, next to "Other calendars", '
                    'choose + → From URL and paste the link.\n'
                    '• Outlook: choose Add calendar → Subscribe from web and paste the link.',
                    style: theme.textTheme.bodySmall,
                  ),
                  const SizedBox(height: 12),
                  Text(
                    "Anyone with this link can see your habits' names and times, so keep "
                    "it to yourself. If it's ever shared by mistake, make a new one.",
                    style: muted,
                  ),
                ],
              ),
            );
          },
        ),
      ),
      actions: [
        TextButton(onPressed: _replace, child: const Text('Make a new link')),
        FilledButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Done'),
        ),
      ],
    );
  }
}
