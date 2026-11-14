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
  String? _calendarMessage;

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
                            'Remote access, people, calendars and sign-in options',
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
              section('Calendar'),
              Card(
                child: Column(
                  children: [
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
                    if (signedIn)
                      ListTile(
                        leading: const Icon(Icons.event_repeat),
                        title: const Text('Refresh external calendars'),
                        subtitle: Text(
                          _calendarMessage ?? 'Google, iCloud and other calendars set up on the server.',
                        ),
                        onTap: () async {
                          setState(() => _calendarMessage = 'Refreshing…');
                          final message = await sync.refreshCalendars();
                          if (mounted) {
                            setState(() => _calendarMessage = message);
                          }
                        },
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
              subtitle: const Text(
                'Everyone gets their own private tasks and habits',
              ),
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
