@Tags(['e2e'])
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dsh_link/dsh_link.dart';
import 'package:test/test.dart';

/// The phone end (this package) against the real dsh-go-link daemon from host/dsh-go-link, with a
/// fake agent on the daemon's unix socket. Needs `node` on PATH.
void main() {
  final script = File('../../host/dsh-go-link/bin/dsh-go-link.cjs').absolute.path;
  final hasNode = Process.runSync('node', ['--version'], runInShell: true).exitCode == 0;
  late Directory home;
  late Map<String, String> env;

  setUp(() {
    home = Directory.systemTemp.createTempSync('dgl-');
    env = {...Platform.environment, 'DSH_GO_LINK_HOME': home.path};
  });

  tearDown(() async {
    await Process.run('node', [script, 'stop'], environment: env);
    home.deleteSync(recursive: true);
  });

  test('a phone attaches, an agent lists the tools and its call reaches the phone with its name', () async {
    final start = await Process.run('node', [script, 'start', '--json'], environment: env);
    expect(start.exitCode, 0, reason: '${start.stderr}');
    final line = (start.stdout as String).split('\n').firstWhere((l) => l.startsWith('DSHGOLINK '));
    final endpoint = jsonDecode(line.substring(10)) as Map;

    final socket = await Socket.connect(InternetAddress.loopbackIPv4, endpoint['port'] as int);
    final session = await LinkSession.open(
      input: socket,
      output: socket,
      token: endpoint['token'] as String,
      phone: const LinkPhone(id: 'p1', name: 'Pixel 9', app: 'test'),
      mcp: const {
        'tools': [
          {
            'name': 'screen',
            'description': '读屏',
            'inputSchema': {'type': 'object'},
          },
        ],
        'instructions': 'Call screen first.',
      },
      onClose: socket.destroy,
    );
    addTearDown(session.close);
    expect(session.host.linkVersion, isNotEmpty);

    final opened = <String>[];
    LinkMcpRouter(
      session,
      open: (ch, origin) async => opened.add('${origin.name}'),
      line: (ch, l) async {
        final m = jsonDecode(l) as Map;
        final name = (m['params'] as Map)['name'];
        return jsonEncode({
          'jsonrpc': '2.0',
          'id': m['id'],
          'result': {
            'content': [
              {'type': 'text', 'text': 'did $name'},
            ],
            'isError': false,
          },
        });
      },
      close: (ch) async {},
    );

    final info = jsonDecode(File('${home.path}/daemon.json').readAsStringSync()) as Map;
    final shim = info['shim'] as Map;
    final agent = await Socket.connect(InternetAddress(shim['path'] as String, type: InternetAddressType.unix), 0);
    addTearDown(agent.destroy);
    final replies = StreamIterator(splitLines(agent).map((l) => jsonDecode(l) as Map<Object?, Object?>));
    Future<Map<Object?, Object?>> next() async {
      expect(await replies.moveNext().timeout(const Duration(seconds: 5)), isTrue);
      return replies.current;
    }

    void say(Object v) => agent.add(utf8.encode('${jsonEncode(v)}\n'));
    say({'dshGoLinkShim': 1, 'token': shim['token']});
    expect(await next(), {'ok': true});
    say({
      'jsonrpc': '2.0',
      'id': 1,
      'method': 'initialize',
      'params': {
        'protocolVersion': '2025-06-18',
        'clientInfo': {'name': 'claude-code', 'version': '2'},
      },
    });
    expect(((await next())['result'] as Map)['instructions'], 'Call screen first.');
    say({'jsonrpc': '2.0', 'id': 2, 'method': 'tools/list'});
    expect((((await next())['result'] as Map)['tools'] as List).single['name'], 'screen');
    say({
      'jsonrpc': '2.0',
      'id': 3,
      'method': 'tools/call',
      'params': {'name': 'screen', 'arguments': <String, Object?>{}},
    });
    final result = (await next())['result'] as Map;
    expect((result['content'] as List).single['text'], 'did screen');
    expect(opened, ['claude-code']);

    final status = await Process.run('node', [script, 'status', '--json'], environment: env);
    final s = jsonDecode((status.stdout as String).trim().substring(10)) as Map;
    expect((s['phone'] as Map)['name'], 'Pixel 9');
    expect(s['agents'], ['claude-code']);
  }, skip: hasNode ? false : 'node is not on PATH');
}
