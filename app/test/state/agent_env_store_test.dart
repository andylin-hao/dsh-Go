// An agent's environment on a computer: kept in the secret store, per computer and agent.

import 'package:dsh_app/remote/secret_store.dart';
import 'package:dsh_app/state/remote_agents_state.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('round trip per computer and agent; empty removes it; bad entries are dropped', () async {
    final secrets = MemorySecretStore();
    final store = AgentEnvStore(secrets);
    expect(await store.read('lan-abc', 'codex'), isEmpty);

    await store.write('lan-abc', 'codex', {'OPENAI_API_KEY': 'sk-1', 'HTTPS_PROXY': 'http://p:8080'});
    expect(await store.read('lan-abc', 'codex'), {'OPENAI_API_KEY': 'sk-1', 'HTTPS_PROXY': 'http://p:8080'});
    expect(await store.read('lan-abc', 'claude-code'), isEmpty);
    expect(await store.read('ssh-other', 'codex'), isEmpty);
    // Only in the secret store, under its own key.
    expect(secrets.values.keys, ['agents.env.lan-abc.codex']);

    await store.write('lan-abc', 'codex', const {});
    expect(secrets.values, isEmpty);

    secrets.values['agents.env.lan-abc.codex'] = '{"GOOD":"1","1BAD":"x","ALSO_BAD":2}';
    expect(await store.read('lan-abc', 'codex'), {'GOOD': '1'});
    secrets.values['agents.env.lan-abc.codex'] = 'not json';
    expect(await store.read('lan-abc', 'codex'), isEmpty);
  });

  test('names are shell variable names', () {
    for (final ok in ['A', '_A', 'ANTHROPIC_BASE_URL', 'a1']) {
      expect(AgentEnvStore.name.hasMatch(ok), isTrue, reason: ok);
    }
    for (final bad in ['', '1A', 'A-B', 'A B', 'A=B']) {
      expect(AgentEnvStore.name.hasMatch(bad), isFalse, reason: bad);
    }
  });
}
