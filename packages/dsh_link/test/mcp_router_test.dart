import 'dart:async';
import 'dart:convert';

import 'package:dsh_link/dsh_link.dart';
import 'package:test/test.dart';

import 'link_session_test.dart' show FakeDaemon, pumpUntil;

void main() {
  late FakeDaemon d;
  late LinkSession s;
  late List<String> calls;

  setUp(() async {
    d = FakeDaemon();
    s = await d.attach(reply: FakeDaemon.ok);
    calls = [];
  });

  LinkMcpRouter router({Future<String?> Function(String ch, String line)? line, bool failOpen = false}) =>
      LinkMcpRouter(
        s,
        open: (ch, origin) async {
          calls.add('open $ch ${origin.name}');
          if (failOpen) throw StateError('no');
        },
        line: line ?? (ch, l) async => '{"jsonrpc":"2.0","id":${(jsonDecode(l) as Map)['id']},"result":{"ok":"$ch"}}',
        close: (ch) async => calls.add('close $ch'),
      );

  test('a channel opens on the phone before its first line, and every request is answered', () async {
    final r = router();
    d.say({
      't': 'open',
      'ch': 'm1',
      'kind': 'mcp',
      'origin': {'name': 'opencode'},
    });
    d.say({
      't': 'data',
      'ch': 'm1',
      'line': '{"jsonrpc":"2.0","id":5,"method":"tools/call","params":{"name":"screen"}}',
    });
    expect(await d.next(), {'t': 'data', 'ch': 'm1', 'line': '{"jsonrpc":"2.0","id":5,"result":{"ok":"m1"}}'});
    expect(calls, ['open m1 opencode']);
    expect(r.channels, 1);
    d.say({'t': 'close', 'ch': 'm1'});
    await pumpUntil(() => calls.length == 2);
    expect(calls.last, 'close m1');
    expect(r.channels, 0);
  });

  test('a failing relay still answers: a tool error for calls, a JSON-RPC error otherwise', () async {
    router(line: (ch, l) async => throw StateError('platform gone'));
    d.say({'t': 'open', 'ch': 'm1', 'kind': 'mcp'});
    d.say({'t': 'data', 'ch': 'm1', 'line': '{"jsonrpc":"2.0","id":"a","method":"tools/call","params":{}}'});
    final call = jsonDecode((await d.next())['line'] as String) as Map;
    expect(call['id'], 'a');
    expect((call['result'] as Map)['isError'], isTrue);
    expect(((call['result'] as Map)['content'] as List).single['text'], startsWith('[PHONE_ERROR]'));
    d.say({'t': 'data', 'ch': 'm1', 'line': '{"jsonrpc":"2.0","id":2,"method":"other"}'});
    final other = jsonDecode((await d.next())['line'] as String) as Map;
    expect((other['error'] as Map)['code'], -32603);
  });

  test('a channel the phone could not open answers its calls and is never closed on the phone', () async {
    router(failOpen: true);
    d.say({'t': 'open', 'ch': 'm1', 'kind': 'mcp'});
    d.say({'t': 'data', 'ch': 'm1', 'line': '{"jsonrpc":"2.0","id":1,"method":"tools/call"}'});
    final reply = jsonDecode((await d.next())['line'] as String) as Map;
    expect((reply['result'] as Map)['isError'], isTrue);
    d.say({'t': 'close', 'ch': 'm1'});
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(calls, ['open m1 null']);
  });

  test('another kind of channel is refused', () async {
    router();
    d.say({'t': 'open', 'ch': 'a1', 'kind': 'acp'});
    final frame = await d.next();
    expect(frame['t'], 'close');
    expect(frame['ch'], 'a1');
    expect(calls, isEmpty);
  });

  test('the link ending closes every channel on the phone', () async {
    router();
    d.say({'t': 'open', 'ch': 'm1', 'kind': 'mcp'});
    d.say({'t': 'open', 'ch': 'm2', 'kind': 'mcp'});
    await pumpUntil(() => calls.length == 2);
    unawaited(d.toPhone.close());
    await s.done;
    await pumpUntil(() => calls.length == 4);
    expect(calls.sublist(2), unorderedEquals(['close m1', 'close m2']));
  });

  test('mcpFailure ignores notifications and garbage', () {
    expect(mcpFailure('{"jsonrpc":"2.0","method":"notifications/cancelled"}', 'x'), isNull);
    expect(mcpFailure('nope', 'x'), isNull);
    expect(mcpFailure('{"jsonrpc":"2.0","id":null,"method":"ping"}', 'x'), isNull);
  });
}
