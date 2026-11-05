// An SSH host without DSH, its agents attached (dsh-go-link): the DSH connection is tried once
// and then left alone, so the side bar keeps showing the agents instead of reconnecting.
import 'dart:async';
import 'dart:convert';

import 'package:dsh_app/remote/link_status.dart';
import 'package:dsh_app/remote/secret_store.dart';
import 'package:dsh_app/remote/ssh/ssh_link.dart';
import 'package:dsh_app/state/connection_state.dart';
import 'package:dsh_app/state/hosts_state.dart';
import 'package:dsh_app/state/remote_agents_state.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/fake_relay.dart';
import 'support/fake_ssh.dart';

class _NoLocal extends LocalConnectionController {
  @override
  Future<HostConnection?> build() async => null;
}

class _Agents extends RemoteAgentsController {
  @override
  Map<String, AgentComputer> build() => {
    sampleSsh.id: AgentComputer(id: sampleSsh.id, name: sampleSsh.name, loading: false),
  };
}

void main() {
  test('a status listener paused from the start (a closed side bar) still ends on the link\'s latest status', () async {
    SharedPreferences.setMockInitialValues({
      HostsController.prefsKey: jsonEncode([sampleSsh.toJson()]),
      ActiveHostController.prefsKey: HostRef.ssh(sampleSsh.id).encode(),
    });
    final server = FakeSshServer()..remote.dshInstalled = false;
    // The SSH connect waits here, so the link sits at "connecting" while the status is watched.
    final gate = Completer<void>();
    final c = ProviderContainer(
      overrides: [
        secretStoreProvider.overrideWithValue(MemorySecretStore()),
        localConnectionProvider.overrideWith(_NoLocal.new),
        networkKicksProvider.overrideWithValue(const Stream.empty()),
        relayBackendProvider.overrideWithValue(FakeRelayBackend(user: sampleRelayUser)),
        sshLinkFactoryProvider.overrideWithValue(
          (ref, config) => SshHostLink(
            config: config,
            loadSecrets: () async => const SshSecrets(password: 'pw'),
            transportFactory: (params, verify) async {
              await gate.future;
              return server.connect(params, verify);
            },
            connectClient: FakeConnector().call,
          ),
        ),
      ],
    );
    addTearDown(c.dispose);
    final host = HostRef.ssh(sampleSsh.id);
    final active = c.listen(activeConnectionProvider, (_, _) {});
    addTearDown(active.close);
    await c.read(hostsProvider.notifier).ready;
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(c.read(hostLinkProvider(host))!.status.phase, HostLinkPhase.connecting);
    // Watched, but paused right away: what Riverpod does for a widget no one sees.
    final status = c.listen(hostLinkStatusProvider(host), (_, _) {})..pause();
    addTearDown(status.close);
    await Future<void>.delayed(const Duration(milliseconds: 20));
    gate.complete();
    await Future<void>.delayed(const Duration(milliseconds: 200));
    expect(c.read(hostLinkProvider(host))!.status.error?.kind, HostLinkErrorKind.dshNotFound);
    status.resume();
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(c.read(hostLinkStatusProvider(host)).value?.error?.kind, HostLinkErrorKind.dshNotFound);
  });

  test('currentAndChanges: the current value, then changes, none lost while paused', () async {
    final changes = StreamController<int>.broadcast(sync: true);
    var current = 1;
    final seen = <int>[];
    final sub = currentAndChanges(() => current, changes.stream).listen(seen.add);
    sub.pause();
    current = 2;
    changes.add(2);
    changes.add(3);
    sub.resume();
    await Future<void>.delayed(Duration.zero);
    expect(seen, [1, 2, 3]);
    await sub.cancel();
    expect(changes.hasListener, isFalse);
  });

  test('no DSH, agents attached: one DSH attempt, then the agents stay', () async {
    SharedPreferences.setMockInitialValues({
      HostsController.prefsKey: jsonEncode([sampleSsh.toJson()]),
      ActiveHostController.prefsKey: HostRef.ssh(sampleSsh.id).encode(),
    });
    final server = FakeSshServer()..remote.dshInstalled = false;
    final c = ProviderContainer(
      overrides: [
        secretStoreProvider.overrideWithValue(MemorySecretStore()),
        localConnectionProvider.overrideWith(_NoLocal.new),
        networkKicksProvider.overrideWithValue(const Stream.empty()),
        relayBackendProvider.overrideWithValue(FakeRelayBackend(user: sampleRelayUser)),
        remoteAgentsProvider.overrideWith(_Agents.new),
        sshLinkFactoryProvider.overrideWithValue(
          (ref, config) => SshHostLink(
            config: config,
            loadSecrets: () async => const SshSecrets(password: 'pw'),
            transportFactory: server.connect,
            connectClient: FakeConnector().call,
            backoff: Backoff(initial: const Duration(milliseconds: 1), maxAttempts: 2),
          ),
        ),
      ],
    );
    addTearDown(c.dispose);
    final host = HostRef.ssh(sampleSsh.id);
    // What the side bar keeps alive: the active connection, the host's status, the agents view.
    final subs = [
      c.listen(activeConnectionProvider, (_, _) {}),
      c.listen(hostLinkStatusProvider(host), (_, _) {}),
      c.listen(agentsOnlyHostProvider(host), (_, _) {}),
    ];
    addTearDown(() {
      for (final s in subs) {
        s.close();
      }
    });
    await c.read(hostsProvider.notifier).ready;
    final deadline = DateTime.now().add(const Duration(seconds: 3));
    while (DateTime.now().isBefore(deadline)) {
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
    expect(c.read(hostLinkStatusProvider(host)).value?.error?.kind, HostLinkErrorKind.dshNotFound);
    expect(c.read(agentsOnlyHostProvider(host))?.name, sampleSsh.name);
    expect(server.connects, hasLength(1), reason: 'the DSH connection was tried ${server.connects.length} times');
  });
}
