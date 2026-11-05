// An SSH host without DSH whose agents are attached (dsh-go-link): connected for its agents.

import 'package:dsh_app/state/connection_state.dart';
import 'package:dsh_app/state/hosts_state.dart';
import 'package:dsh_app/state/remote_agents_state.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

class _Agents extends RemoteAgentsController {
  _Agents(this.computers);

  final Map<String, AgentComputer> computers;

  @override
  Map<String, AgentComputer> build() => computers;
}

void main() {
  const host = HostRef.ssh('ssh-dev-box');
  const computer = AgentComputer(id: 'ssh-dev-box', name: 'dev-box', loading: false);
  const noDsh = HostLinkStatus(HostLinkPhase.failed, error: HostLinkError(HostLinkErrorKind.dshNotFound, 'no dsh'));

  Future<AgentComputer?> read(HostRef h, HostLinkStatus status, Map<String, AgentComputer> computers) async {
    final c = ProviderContainer(
      overrides: [
        hostLinkStatusProvider.overrideWith((ref, _) => Stream.value(status)),
        remoteAgentsProvider.overrideWith(() => _Agents(computers)),
      ],
    );
    addTearDown(c.dispose);
    final sub = c.listen(agentsOnlyHostProvider(h), (_, _) {});
    addTearDown(sub.close);
    // Only an SSH host's link status is read at all.
    if (h.kind == HostKind.ssh) await c.read(hostLinkStatusProvider(h).future);
    return c.read(agentsOnlyHostProvider(h));
  }

  test('no DSH on the host, its agents attached: the agents computer', () async {
    expect((await read(host, noDsh, {'ssh-dev-box': computer}))?.name, 'dev-box');
  });

  test('anything else stays as it was', () async {
    // Agents not attached (or not turned on for this host).
    expect(await read(host, noDsh, const {}), isNull);
    // Another failure: the host is really unreachable.
    const down = HostLinkStatus(HostLinkPhase.failed, error: HostLinkError(HostLinkErrorKind.unreachable, 'down'));
    expect(await read(host, down, {'ssh-dev-box': computer}), isNull);
    // DSH connected: its conversations, as before.
    expect(await read(host, const HostLinkStatus(HostLinkPhase.connected), {'ssh-dev-box': computer}), isNull);
    // Not an SSH host.
    expect(await read(const HostRef.relay('ssh-dev-box'), noDsh, {'ssh-dev-box': computer}), isNull);
  });
}
