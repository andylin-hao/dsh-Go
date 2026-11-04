// dsh-go-link from the app's side: the install/start scripts against the local /bin/sh and Node
// in a temp HOME (the SSH session's stand-in), and PhoneLink attached to the real daemon through
// a local "tunnel", with a fake phone and a fake agent on the daemon's socket.

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dsh_app/remote/link/lan_link.dart';
import 'package:dsh_app/remote/link/link_bootstrap.dart';
import 'package:dsh_app/remote/link/phone_link.dart';
import 'package:dsh_app/remote/link_status.dart';
import 'package:dsh_app/remote/secret_store.dart';
import 'package:dsh_app/remote/ssh/remote_shell.dart';
import 'package:dsh_app/remote/ssh/ssh_host_config.dart';
import 'package:dsh_app/remote/ssh/ssh_transport.dart';
import 'package:dsh_link/dsh_link.dart';
import 'package:flutter_test/flutter_test.dart';

final _script = File('assets/link/dsh-go-link.cjs').readAsStringSync();
final _hasNode = Process.runSync('node', ['--version'], runInShell: true).exitCode == 0;
const _key = PresentedHostKey('ssh-ed25519', 'SHA256:pinnedpinnedpinnedpinnedpinnedpinned0000');

/// This machine as the "computer": scripts run in /bin/sh with [home] as HOME, tunnels are TCP.
class LocalTransport implements SshTransport {
  LocalTransport(String home) : _shell = LocalProcessShell(environment: {...Platform.environment, 'HOME': home});

  final LocalProcessShell _shell;
  final _done = Completer<void>();
  final scripts = <String>[];

  @override
  Future<RemoteExecResult> run(String script, {Duration timeout = const Duration(seconds: 30)}) {
    scripts.add(script);
    return _shell.run(script, timeout: timeout);
  }

  @override
  Future<TunnelChannel> openTunnel(String host, int port) async => _SocketChannel(await Socket.connect(host, port));

  @override
  Future<void> ping({Duration timeout = const Duration(seconds: 10)}) async {}

  @override
  Future<void> get done => _done.future;

  @override
  bool get isClosed => _done.isCompleted;

  @override
  void close() {
    if (!_done.isCompleted) _done.complete();
  }
}

class _SocketChannel implements TunnelChannel {
  _SocketChannel(this._socket);

  final Socket _socket;

  @override
  Stream<Uint8List> get stream => _socket;

  @override
  StreamSink<List<int>> get sink => _socket;

  @override
  void destroy() => _socket.destroy();
}

class FakePhone implements PhoneLinkRemote {
  final opened = <String, ({String key, String? client, String host})>{};
  final closed = <String>[];
  final lines = <(String, String)>[];

  @override
  Future<Map<String, Object?>> catalog() async => {
    'tools': [
      {
        'name': 'screen',
        'description': '读屏',
        'inputSchema': {'type': 'object'},
      },
    ],
    'instructions': 'Call screen first.',
  };

  @override
  Future<void> open(String ch, {required String key, String? client, required String host}) async =>
      opened[ch] = (key: key, client: client, host: host);

  @override
  Future<String?> line(String ch, String line) async {
    lines.add((ch, line));
    final id = (jsonDecode(line) as Map)['id'];
    return jsonEncode({
      'jsonrpc': '2.0',
      'id': id,
      'result': {
        'content': [
          {'type': 'text', 'text': 'ok'},
        ],
        'isError': false,
      },
    });
  }

  @override
  Future<void> close(String ch) async => closed.add(ch);

  final finished = <String>[];

  @override
  Future<void> finish(String key) async => finished.add(key);
}

/// An agent (what `dsh-go-link mcp` does) on the daemon's shim socket.
class FakeAgent {
  FakeAgent._(this._socket, this._lines);

  static Future<FakeAgent> connect(String home, {String name = 'claude-code'}) async {
    final info = jsonDecode(File('$home/.dsh-go/link/daemon.json').readAsStringSync()) as Map;
    final shim = info['shim'] as Map;
    final socket = await Socket.connect(InternetAddress(shim['path'] as String, type: InternetAddressType.unix), 0);
    final agent = FakeAgent._(socket, StreamIterator(splitLines(socket)));
    agent.say({'dshGoLinkShim': 1, 'token': shim['token']});
    expect(await agent.next(), {'ok': true});
    agent.say({
      'jsonrpc': '2.0',
      'id': 0,
      'method': 'initialize',
      'params': {
        'clientInfo': {'name': name},
      },
    });
    await agent.next();
    return agent;
  }

  final Socket _socket;
  final StreamIterator<String> _lines;

  void say(Object v) => _socket.add(utf8.encode('${jsonEncode(v)}\n'));

  Future<Map<Object?, Object?>> next() async {
    expect(await _lines.moveNext().timeout(const Duration(seconds: 10)), isTrue);
    return jsonDecode(_lines.current) as Map<Object?, Object?>;
  }

  void close() => _socket.destroy();
}

SshHostConfig _host({String? fingerprint = 'SHA256:pinnedpinnedpinnedpinnedpinnedpinned0000'}) => SshHostConfig(
  id: 'ssh-1',
  name: 'dev-box',
  host: 'dev.example',
  user: 'me',
  hostKeyType: 'ssh-ed25519',
  hostKeyFingerprint: fingerprint,
);

Future<void> _stopDaemon(String home) => Process.run(
  'node',
  ['$home/.dsh-go/link/bin/dsh-go-link.cjs', 'stop'],
  environment: {...Platform.environment, 'HOME': home},
);

Future<PhoneLinkStatus> _until(PhoneLink link, bool Function(PhoneLinkStatus) ok) async {
  if (ok(link.status)) return link.status;
  return link.statuses.firstWhere(ok).timeout(const Duration(seconds: 20));
}

void main() {
  late Directory home;

  setUp(() => home = Directory.systemTemp.createTempSync('dgl-app-'));
  tearDown(() async {
    if (_hasNode) await _stopDaemon(home.path);
    home.deleteSync(recursive: true);
  });

  group('LinkBootstrap', () {
    test('installs the script owner-only, starts the daemon, and reuses both next time', () async {
      final shell = LocalTransport(home.path);
      final b = LinkBootstrap(shell, script: _script);
      final first = await b.ensure();
      expect(first.port, greaterThan(0));
      expect(first.token, matches(RegExp(r'^[0-9a-f]{64}$')));
      // Nothing installed yet: a probe, the upload in pieces, then the install and start.
      final pieces = (base64.encode(utf8.encode(_script)).length / LinkBootstrap.uploadChunk).ceil();
      expect(pieces, greaterThan(1));
      expect(shell.scripts, hasLength(2 + pieces));
      // Each command is one `sh -c` argument: Linux refuses one over 128 KiB.
      for (final script in shell.scripts) {
        expect(utf8.encode(script).length, lessThan(128 * 1024));
      }
      final installed = File('${home.path}/.dsh-go/link/bin/dsh-go-link.cjs');
      expect(installed.readAsStringSync(), _script);
      expect(installed.statSync().mode & 0x1ff, 0x1c0); // 0700
      expect(Directory('${home.path}/.dsh-go/link').statSync().mode & 0x1ff, 0x1c0);
      expect(File('${home.path}/.dsh-go/link/bin/dsh-go-link.b64').existsSync(), isFalse);

      final again = await b.ensure();
      expect(shell.scripts, hasLength(3 + pieces));
      expect(again.pid, first.pid);
      expect(again.token, first.token);

      final setup = await b.agentSetup();
      expect(setup.map((a) => a.id), ['claude-code', 'codex', 'opencode', 'antigravity', 'antigravity-ide', 'other']);
      expect(setup.first.command, isTrue);
      expect(setup.first.text, contains('${home.path}/.dsh-go/link/bin/dsh-go-link.cjs mcp'));
      expect(setup[1].file, '~/.codex/config.toml');
    }, skip: _hasNode ? false : 'node is not on PATH');

    test('an old Node on PATH is passed over for a newer one in a Nix profile', () async {
      // As on a host whose distribution ships Node 12 in /usr/bin and Node 24 in ~/.nix-profile.
      final real = File(Process.runSync('sh', ['-c', 'command -v node']).stdout.toString().trim()).resolveSymbolicLinksSync();
      final old = Directory('${home.path}/old-bin')..createSync();
      File('${old.path}/node').writeAsStringSync('#!/bin/sh\necho 12.22.9\n');
      Process.runSync('chmod', ['755', '${old.path}/node']);
      Link('${home.path}/.nix-profile/bin/node').createSync(real, recursive: true);
      final b = LinkBootstrap(LocalTransport(home.path), script: _script, environment: {'PATH': '${old.path}:/usr/bin:/bin'});
      expect((await b.ensure()).port, greaterThan(0));
      // The daemon and the agents' entries use the Nix profile's Node.
      expect((await b.agentSetup()).first.text, contains(real));
    }, skip: _hasNode ? false : 'node is not on PATH');

    test('a changed copy is uploaded again', () async {
      final shell = LocalTransport(home.path);
      await LinkBootstrap(shell, script: _script).ensure();
      final next = '$_script\n// next build\n';
      await LinkBootstrap(shell, script: next).ensure();
      expect(File('${home.path}/.dsh-go/link/bin/dsh-go-link.cjs').readAsStringSync(), next);
    }, skip: _hasNode ? false : 'node is not on PATH');

    test('failures are read from the tagged lines, and token lines never reach details', () {
      final b = LinkBootstrap(LocalProcessShell(), script: 'x');
      LinkBootstrapError failure(String out, [String err = '']) {
        try {
          b.parseStart(RemoteExecResult(0, out, err));
        } on LinkBootstrapError catch (e) {
          return e;
        }
        fail('no error');
      }

      expect(failure('Welcome!\nDSHGOLINK-ERR node_missing\n').failure, LinkBootstrapFailure.nodeMissing);
      final old = failure('DSHGOLINK-ERR node_old 16.20.2\n');
      expect(old.failure, LinkBootstrapFailure.nodeOld);
      expect(old.detail, '16.20.2');
      expect(failure('DSHGOLINK-ERR install\n', 'hash mismatch').failure, LinkBootstrapFailure.install);
      final start = failure('dsh-go-link: the daemon did not start\nDSHGOLINK-ERR start\n');
      expect(start.failure, LinkBootstrapFailure.start);
      expect(start.detail, contains('did not start'));
      expect(failure('', "sh: not found").failure, LinkBootstrapFailure.noShell);
      final garbled = failure('DSHGOLINK {"port":"x","token":"secret"}\n');
      expect(garbled.failure, LinkBootstrapFailure.start);
      expect(garbled.detail, isNot(contains('secret')));
      final ok = b.parseStart(
        const RemoteExecResult(0, 'motd\nDSHGOLINK {"v":1,"version":"0.1.0","pid":7,"port":4100,"token":"t"}\n', ''),
      );
      expect((ok.port, ok.token, ok.pid, ok.version), (4100, 't', 7, '0.1.0'));
    });
  });

  group('PhoneLink', () {
    PhoneLink link(FakePhone phone, {SshHostConfig? config, Future<SshTransport> Function()? connect}) => PhoneLink(
      dialer: SshLinkDialer(
        config: config ?? _host(),
        loadSecrets: () async => const SshSecrets(password: 'pw'),
        transportFactory: (params, verify) async {
          if (!await verify(_key)) throw const HostLinkError(HostLinkErrorKind.hostKeyRejected, 'rejected');
          return connect == null ? LocalTransport(home.path) : await connect();
        },
        script: () async => _script,
      ),
      remote: phone,
      phone: const LinkPhone(id: 'p', name: 'Pixel'),
      backoff: Backoff(initial: const Duration(milliseconds: 50), maxAttempts: null),
    );

    test('attaches, names the computer and the agents, and relays calls on namespaced channels', () async {
      final phone = FakePhone();
      final l = link(phone)..start();
      addTearDown(l.close);
      final attached = await _until(l, (s) => s.attached);
      expect(attached.computer, Platform.localHostname);
      expect(attached.agents, isEmpty);

      final agent = await FakeAgent.connect(home.path);
      addTearDown(agent.close);
      agent.say({'jsonrpc': '2.0', 'id': 1, 'method': 'tools/list'});
      expect((((await agent.next())['result'] as Map)['tools'] as List).single['name'], 'screen');
      agent.say({
        'jsonrpc': '2.0',
        'id': 2,
        'method': 'tools/call',
        'params': {'name': 'screen', 'arguments': <String, Object?>{}},
      });
      final result = (await agent.next())['result'] as Map;
      expect((result['content'] as List).single['text'], 'ok');

      final ch = phone.opened.keys.single;
      expect(ch, startsWith('ssh:ssh-1/m'));
      expect(phone.opened[ch], (key: ch, client: 'claude-code', host: 'dev-box'));
      expect(phone.lines.single.$1, ch);
      expect((await _until(l, (s) => s.agents.isNotEmpty)).agents, ['claude-code']);

      agent.close();
      await _until(l, (s) => s.agents.isEmpty);
      expect(phone.closed, [ch]);
    }, skip: _hasNode ? false : 'node is not on PATH');

    test('a host whose key was never confirmed, or changed, fails without connecting', () async {
      final phone = FakePhone();
      final unknown = link(phone, config: _host(fingerprint: null))..start();
      addTearDown(unknown.close);
      final s = await _until(unknown, (s) => s.phase == PhoneLinkPhase.failed);
      expect(s.error!.kind, PhoneLinkErrorKind.hostKeyUnknown);
      final changed = link(phone, config: _host(fingerprint: 'SHA256:other'))..start();
      addTearDown(changed.close);
      expect(
        (await _until(changed, (s) => s.phase == PhoneLinkPhase.failed)).error!.kind,
        PhoneLinkErrorKind.hostKeyChanged,
      );
      expect(phone.opened, isEmpty);
    });

    test('an unreachable host keeps retrying; Node missing needs the person', () async {
      var attempts = 0;
      final flaky = link(
        FakePhone(),
        connect: () async {
          attempts++;
          throw const HostLinkError(HostLinkErrorKind.unreachable, 'down', retryable: true);
        },
      )..start();
      addTearDown(flaky.close);
      final waiting = await _until(flaky, (s) => s.phase == PhoneLinkPhase.waiting);
      expect(waiting.error!.kind, PhoneLinkErrorKind.ssh);
      expect(waiting.error!.message, 'down');
      await _until(flaky, (_) => attempts >= 3);

      final noNode = link(FakePhone(), connect: () async => _ScriptedTransport('DSHGOLINK-ERR node_missing\n'))
        ..start();
      addTearDown(noNode.close);
      expect(
        (await _until(noNode, (s) => s.phase == PhoneLinkPhase.failed)).error!.kind,
        PhoneLinkErrorKind.nodeMissing,
      );
    });

    test('another phone taking the computer over stops this link for good', () async {
      final l = link(FakePhone())..start();
      addTearDown(l.close);
      await _until(l, (s) => s.attached);
      final endpoint = await LinkBootstrap(LocalTransport(home.path), script: _script).ensure();
      final socket = await Socket.connect('127.0.0.1', endpoint.port);
      final other = await LinkSession.open(
        input: socket,
        output: socket,
        token: endpoint.token,
        phone: const LinkPhone(id: 'q', name: 'Other'),
        onClose: socket.destroy,
      );
      addTearDown(other.close);
      final s = await _until(l, (s) => s.phase == PhoneLinkPhase.failed);
      expect(s.error!.kind, PhoneLinkErrorKind.replaced);
    }, skip: _hasNode ? false : 'node is not on PATH');
  });

  _lanAndCockpit(() => home);
}

void _lanAndCockpit(Directory Function() homeOf) {
  group('network pairing', () {
    test('a pairing link from the computer: Noise to its pinned key, then the phone key alone', () async {
      final home = homeOf();
      // Install and start the daemon the way the SSH path does, then pair as a user would.
      await LinkBootstrap(LocalTransport(home.path), script: _script).ensure();
      final port = await _freePort();
      final pairing = await _pairOnComputer(home.path, port);
      expect(pairing.addresses.single.port, port);
      final computer = LanComputer.of(pairing);
      expect(computer.id, startsWith('lan-'));
      expect(computer.fingerprint, matches(RegExp(r'^[A-Z0-9]{4} [A-Z0-9]{4} [A-Z0-9]{4}$')));
      final identity = LinkIdentity.load(MemorySecretStore());
      final phone = FakePhone();
      PhoneLink lan({String? secret, Future<LinkIdentity>? id}) => PhoneLink(
        dialer: LanLinkDialer(computer: computer, identity: () => id ?? identity, pairingSecret: secret),
        remote: phone,
        phone: const LinkPhone(id: 'p', name: 'Pixel'),
        backoff: Backoff(initial: const Duration(milliseconds: 50), maxAttempts: null),
      );
      final first = lan(secret: pairing.secret)..start();
      final attached = await _until(first, (s) => s.attached);
      expect(attached.caps, contains('agents.acp.v1'));
      await first.close();

      // Same phone key, no secret: still accepted, and an agent's call reaches the phone.
      final again = lan()..start();
      addTearDown(again.close);
      expect((await _until(again, (s) => s.attached)).attached, isTrue);
      final agent = await FakeAgent.connect(home.path, name: 'opencode');
      addTearDown(agent.close);
      agent.say({
        'jsonrpc': '2.0',
        'id': 1,
        'method': 'tools/call',
        'params': {'name': 'screen'},
      });
      expect((((await agent.next())['result'] as Map)['content'] as List).single['text'], 'ok');
      expect(phone.opened.keys.single, startsWith('lan:${computer.id}/m'));
      await again.close();

      // Another phone identity, no secret: refused for good.
      final stranger = lan(id: LinkIdentity.load(MemorySecretStore()))..start();
      addTearDown(stranger.close);
      expect(
        (await _until(stranger, (s) => s.phase == PhoneLinkPhase.failed)).error!.kind,
        PhoneLinkErrorKind.notPaired,
      );
    }, skip: _hasNode ? false : 'node is not on PATH');

    test('pairing links are read strictly', () {
      final key = 'A' * 43;
      LinkPairing? p(String q) => LinkPairing.parse(Uri.parse('dshgo://link?$q'));
      final ok = p('v=1&n=box&k=$key&s=${'b' * 22}&a=192.168.1.2:4000,[fe80::1]:4000,bad');
      expect(ok!.name, 'box');
      expect(ok.addresses.map((a) => '$a'), ['192.168.1.2:4000', '[fe80::1]:4000']);
      expect(p('v=2&n=box&k=$key&s=${'b' * 22}&a=1.2.3.4:1'), isNull);
      expect(p('v=1&n=box&k=short&s=${'b' * 22}&a=1.2.3.4:1'), isNull);
      expect(p('v=1&n=box&k=$key&s=${'b' * 22}&a='), isNull);
      expect(LinkPairing.parse(Uri.parse('https://link?v=1')), isNull);
      final c = LanComputer.of(ok);
      expect(LanComputer.fromJson(c.toJson())!.addresses.map((a) => '$a'), ['192.168.1.2:4000', '[fe80::1]:4000']);
    });

    test('the phone identity is created once and kept', () async {
      final store = MemorySecretStore();
      final a = await LinkIdentity.load(store);
      final b = await LinkIdentity.load(store);
      expect(a.publicKey, b.publicKey);
      expect(a.publicKey.length, 43);
    });
  });
}

/// A "computer" whose every script prints [out].
class _ScriptedTransport extends LocalTransport {
  _ScriptedTransport(this.out) : super(Directory.systemTemp.path);

  final String out;

  @override
  Future<RemoteExecResult> run(String script, {Duration timeout = const Duration(seconds: 30)}) async =>
      RemoteExecResult(0, out, '');
}

/// The computer's own `pair --json` (in [home]), with the given address in the link.
Future<LinkPairing> _pairOnComputer(String home, int port) async {
  final env = {...Platform.environment, 'HOME': home};
  final script = '$home/.dsh-go/link/bin/dsh-go-link.cjs';
  final r = await Process.run('node', [script, 'pair', '--port', '$port', '--address', '127.0.0.1:$port', '--json'], environment: env);
  final line = (r.stdout as String).split('\n').firstWhere((l) => l.startsWith('DSHGOLINK '));
  final link = (jsonDecode(line.substring(10)) as Map)['link'] as String;
  return LinkPairing.parse(Uri.parse(link))!;
}

Future<int> _freePort() async {
  final s = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
  final port = s.port;
  await s.close();
  return port;
}

void lanTests() {}
