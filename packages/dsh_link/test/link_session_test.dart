import 'dart:async';
import 'dart:convert';

import 'package:dsh_link/dsh_link.dart';
import 'package:test/test.dart';

/// The daemon's side of an in-memory link: what the phone wrote, and a way to answer.
class FakeDaemon {
  final toPhone = StreamController<List<int>>();
  final fromPhone = StreamController<List<int>>();
  final _frames = <Map<String, Object?>>[];
  final _waiters = <Completer<Map<String, Object?>>>[];
  var closedByPhone = 0;

  FakeDaemon() {
    splitLines(fromPhone.stream).listen((line) {
      final v = (jsonDecode(line) as Map).cast<String, Object?>();
      if (_waiters.isNotEmpty) {
        _waiters.removeAt(0).complete(v);
      } else {
        _frames.add(v);
      }
    });
  }

  Future<Map<String, Object?>> next() {
    if (_frames.isNotEmpty) return Future.value(_frames.removeAt(0));
    final c = Completer<Map<String, Object?>>();
    _waiters.add(c);
    return c.future.timeout(const Duration(seconds: 3));
  }

  void say(Object frame) => toPhone.add(utf8.encode('${jsonEncode(frame)}\n'));

  Future<LinkSession> attach({
    Map<String, Object?>? reply,
    Duration silenceLimit = const Duration(seconds: 50),
    Duration pingInterval = const Duration(seconds: 20),
    Duration helloTimeout = const Duration(seconds: 10),
  }) async {
    final opening = LinkSession.open(
      input: toPhone.stream,
      output: fromPhone.sink,
      token: 't0k',
      phone: const LinkPhone(id: 'p1', name: 'Pixel', app: '1.0.10'),
      mcp: const {'tools': [], 'instructions': 'x'},
      onClose: () => closedByPhone++,
      silenceLimit: silenceLimit,
      pingInterval: pingInterval,
      helloTimeout: helloTimeout,
    );
    final hello = await next();
    expect(hello, {
      'dshGoLink': 1,
      'token': 't0k',
      'phone': {'id': 'p1', 'name': 'Pixel', 'app': '1.0.10'},
      'mcp': {'tools': <Object?>[], 'instructions': 'x'},
    });
    if (reply != null) say(reply);
    return opening;
  }

  static const ok = {
    'ok': true,
    'link': {'version': '0.1.0', 'protocol': 1},
    'host': {'name': 'dev-box', 'os': 'linux'},
  };
}

void main() {
  test('the hello brings the computer, and channels come and go', () async {
    final d = FakeDaemon();
    final s = await d.attach(reply: FakeDaemon.ok);
    expect(s.host.name, 'dev-box');
    expect(s.host.os, 'linux');
    expect(s.host.linkVersion, '0.1.0');
    final events = <LinkEvent>[];
    s.events.listen(events.add);

    d.say({
      't': 'open',
      'ch': 'm1',
      'kind': 'mcp',
      'origin': {'name': 'claude-code', 'title': 'Claude Code', 'version': '2.0'},
    });
    d.say({'t': 'data', 'ch': 'm1', 'line': '{"id":1}'});
    d.say({'t': 'data', 'ch': 'm9', 'line': 'not open'});
    d.say({'t': 'close', 'ch': 'm1'});
    await pumpUntil(() => events.length == 3);
    final opened = events[0] as ChannelOpened;
    expect(opened.ch, 'm1');
    expect(opened.kind, 'mcp');
    expect(opened.origin.display, 'Claude Code');
    expect(opened.origin.name, 'claude-code');
    expect((events[1] as ChannelData).line, '{"id":1}');
    expect(events[2], isA<ChannelClosed>());
    expect(s.channels, isEmpty);
  });

  test('send and closeChannel write frames only for open channels', () async {
    final d = FakeDaemon();
    final s = await d.attach(reply: FakeDaemon.ok);
    final events = <LinkEvent>[];
    s.events.listen(events.add);
    d.say({'t': 'open', 'ch': 'm2', 'kind': 'mcp', 'origin': <String, Object?>{}});
    await pumpUntil(() => events.isNotEmpty);
    s.send('m2', '{"id":1,"result":{}}');
    s.send('nope', 'dropped');
    expect(await d.next(), {'t': 'data', 'ch': 'm2', 'line': '{"id":1,"result":{}}'});
    s.closeChannel('m2', message: '[ACCESS_OFF] off');
    expect(await d.next(), {'t': 'close', 'ch': 'm2', 'message': '[ACCESS_OFF] off'});
    await pumpUntil(() => events.length == 2);
    expect(events.last, isA<ChannelClosed>());
  });

  test('a refused hello throws with its code and releases the stream', () async {
    final d = FakeDaemon();
    await expectLater(
      d.attach(reply: {'ok': false, 'code': 'bad_token'}),
      throwsA(isA<LinkRefused>().having((e) => e.code, 'code', 'bad_token')),
    );
    expect(d.closedByPhone, 1);
    final d2 = FakeDaemon();
    await expectLater(
      d2.attach(reply: {'what': 1}),
      throwsA(isA<LinkRefused>().having((e) => e.code, 'code', 'malformed')),
    );
  });

  test('no answer to the hello times out', () async {
    final d = FakeDaemon();
    await expectLater(d.attach(helloTimeout: const Duration(milliseconds: 50)), throwsA(isA<TimeoutException>()));
    expect(d.closedByPhone, 1);
  });

  test('bye replaced ends the link and closes every open channel', () async {
    final d = FakeDaemon();
    final s = await d.attach(reply: FakeDaemon.ok);
    final events = <LinkEvent>[];
    final closed = Completer<void>();
    s.events.listen(events.add, onDone: closed.complete);
    d.say({'t': 'open', 'ch': 'm1', 'kind': 'mcp'});
    d.say({'t': 'open', 'ch': 'm2', 'kind': 'mcp'});
    d.say({'t': 'bye', 'code': 'replaced'});
    final end = await s.done;
    expect(end.code, 'replaced');
    expect(end.replaced, isTrue);
    await closed.future;
    expect(events.whereType<ChannelClosed>().map((e) => e.ch), unorderedEquals(['m1', 'm2']));
    expect(d.closedByPhone, 1);
  });

  test('the stream ending is closed; close() says bye', () async {
    final d = FakeDaemon();
    final s = await d.attach(reply: FakeDaemon.ok);
    unawaited(d.toPhone.close());
    expect((await s.done).code, 'closed');

    final d2 = FakeDaemon();
    final s2 = await d2.attach(reply: FakeDaemon.ok);
    expect((await s2.close()).code, 'local');
    expect(await d2.next(), {'t': 'bye'});
  });

  test('pings go out, pings are answered, and silence ends the link', () async {
    final d = FakeDaemon();
    final s = await d.attach(
      reply: FakeDaemon.ok,
      pingInterval: const Duration(milliseconds: 40),
      silenceLimit: const Duration(milliseconds: 300),
    );
    expect(await d.next(), {'t': 'ping'});
    d.say({'t': 'ping'});
    var sawPong = false;
    for (var i = 0; i < 5 && !sawPong; i++) {
      sawPong = (await d.next())['t'] == 'pong';
    }
    expect(sawPong, isTrue);
    expect((await s.done).code, 'silent');
  });

  test('frames right behind the hello reply are not lost', () async {
    final d = FakeDaemon();
    final opening = d.attach();
    // Reply and first frame in one chunk.
    await Future<void>.delayed(Duration.zero);
    d.toPhone.add(
      utf8.encode('${jsonEncode(FakeDaemon.ok)}\n${jsonEncode({'t': 'open', 'ch': 'm1', 'kind': 'mcp'})}\n'),
    );
    final s = await opening;
    final first = await s.events.first;
    expect(first, isA<ChannelOpened>());
  });

  test('calls get their results or errors; notices arrive; the end fails what is pending', () async {
    final d = FakeDaemon();
    final s = await d.attach(
      reply: {
        ...FakeDaemon.ok,
        'caps': ['rpc.v1', 'agents.acp.v1'],
      },
    );
    expect(s.host.caps, ['rpc.v1', 'agents.acp.v1']);
    expect(s.host.has('agents.acp.v1'), isTrue);
    final notices = <LinkNotice>[];
    s.notices.listen(notices.add);
    final ok = s.call('sessions.list');
    final call = await d.next();
    expect(call, {'t': 'call', 'id': 1, 'method': 'sessions.list', 'params': <String, Object?>{}});
    d.say({
      't': 'event',
      'name': 'sessions',
      'data': {'id': 'x'},
    });
    d.say({
      't': 'result',
      'id': 1,
      'result': {'sessions': []},
    });
    expect(await ok, {'sessions': []});
    final bad = s.call('nope', {'a': 1});
    await d.next();
    d.say({
      't': 'result',
      'id': 2,
      'error': {'code': 'unknown_method', 'message': 'no'},
    });
    await expectLater(bad, throwsA(isA<LinkCallError>().having((e) => e.code, 'code', 'unknown_method')));
    expect(notices.single.name, 'sessions');
    final cut = s.call('slow');
    await d.next();
    unawaited(d.toPhone.close());
    await expectLater(cut, throwsA(isA<LinkCallError>().having((e) => e.code, 'code', 'closed')));
    await expectLater(s.call('after'), throwsA(isA<LinkCallError>()));
  });

  test('the pairing secret rides in the hello, and the origin names its session', () async {
    final d = FakeDaemon();
    final opening = LinkSession.open(
      input: d.toPhone.stream,
      output: d.fromPhone.sink,
      token: '',
      phone: const LinkPhone(id: 'p', name: 'Pixel'),
      pairingSecret: 's3cret',
    );
    expect((await d.next())['pair'], 's3cret');
    d.say(FakeDaemon.ok);
    final s = await opening;
    final events = <LinkEvent>[];
    s.events.listen(events.add);
    d.say({
      't': 'open',
      'ch': 'm1',
      'kind': 'mcp',
      'origin': {'name': 'claude-code', 'session': 'abc', 'agent': 'claude-code', 'title': 'Claude Code'},
    });
    await pumpUntil(() => events.isNotEmpty);
    final origin = (events.single as ChannelOpened).origin;
    expect((origin.session, origin.agent, origin.display), ('abc', 'claude-code', 'Claude Code'));
  });

  group('splitLines', () {
    test('joins chunks, strips CR, keeps UTF-8 whole', () async {
      final bytes = utf8.encode('ab\r\n读屏\n');
      final chunks = [bytes.sublist(0, 3), bytes.sublist(3, 6), bytes.sublist(6)];
      expect(await splitLines(Stream.fromIterable(chunks)).toList(), ['ab', '读屏']);
    });

    test('a line over the limit is an error', () async {
      final input = Stream.fromIterable([utf8.encode('0123456789\n')]);
      await expectLater(splitLines(input, max: 4).toList(), throwsA(isA<FormatException>()));
    });
  });
}

Future<void> pumpUntil(bool Function() done) async {
  for (var i = 0; i < 200 && !done(); i++) {
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
  expect(done(), isTrue);
}
