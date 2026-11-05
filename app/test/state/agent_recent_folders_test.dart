// Recent folders of agent sessions, per computer, kept on this phone.

import 'dart:convert';

import 'package:dsh_app/state/remote_agents_state.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  ProviderContainer start() {
    final c = ProviderContainer();
    addTearDown(c.dispose);
    c.listen(agentRecentFoldersProvider, (_, _) {});
    return c;
  }

  test('newest first, once each, per computer, at most eight; removable; kept', () async {
    SharedPreferences.setMockInitialValues({});
    var c = start();
    final recent = c.read(agentRecentFoldersProvider.notifier);
    await recent.add('lan-a', '/home/me/RLinf');
    await recent.add('lan-a', '/home/me/dsh-Go');
    await recent.add('lan-a', '/home/me/RLinf');
    await recent.add('ssh-b', '/srv/app');
    expect(c.read(agentRecentFoldersProvider), {
      'lan-a': ['/home/me/RLinf', '/home/me/dsh-Go'],
      'ssh-b': ['/srv/app'],
    });
    for (var i = 0; i < 10; i++) {
      await recent.add('lan-a', '/p$i');
    }
    expect(c.read(agentRecentFoldersProvider)['lan-a'], hasLength(AgentRecentFolders.max));
    expect(c.read(agentRecentFoldersProvider)['lan-a']!.first, '/p9');

    await recent.remove('ssh-b', '/srv/app');
    expect(c.read(agentRecentFoldersProvider).containsKey('ssh-b'), isFalse);

    // A new run reads them back.
    c = start();
    await c.read(agentRecentFoldersProvider.notifier).add('lan-a', '/p9');
    expect(c.read(agentRecentFoldersProvider)['lan-a'], hasLength(AgentRecentFolders.max));
    expect(c.read(agentRecentFoldersProvider)['lan-a']!.first, '/p9');
  });

  test('unreadable preferences mean no recent folders', () async {
    SharedPreferences.setMockInitialValues({AgentRecentFolders.key: 'not json'});
    var c = start();
    await c.read(agentRecentFoldersProvider.notifier).remove('x', '/y');
    expect(c.read(agentRecentFoldersProvider), isEmpty);

    SharedPreferences.setMockInitialValues({
      AgentRecentFolders.key: jsonEncode({
        'lan-a': ['/ok', 3, ''],
        'bad': 'nope',
      }),
    });
    c = start();
    await c.read(agentRecentFoldersProvider.notifier).add('other', '/z');
    expect(c.read(agentRecentFoldersProvider)['lan-a'], ['/ok']);
    expect(c.read(agentRecentFoldersProvider).containsKey('bad'), isFalse);
  });
}
