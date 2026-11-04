import 'dart:async';

import 'package:dsh_link/dsh_link.dart';

import '../link_status.dart';
import '../ssh/ssh_host_config.dart';
import '../ssh/ssh_link.dart' show HostKeyVerdict, checkHostKey;
import '../ssh/ssh_transport.dart';
import 'lan_link.dart';
import 'link_bootstrap.dart';

/// The phone side of the relay: native `dsh/phone` `remote*` methods in the app, a fake in tests.
abstract class PhoneLinkRemote {
  /// The phone's tool list, instructions and server info, for the hello.
  Future<Map<String, Object?>> catalog();

  Future<void> open(String ch, {required String key, String? client, required String host});

  Future<String?> line(String ch, String line);

  Future<void> close(String ch);

  /// The agent session behind [key] finished its turn: its phone task ends.
  Future<void> finish(String key);
}

enum PhoneLinkPhase {
  /// Opening SSH or the network connection, starting dsh-go-link, attaching.
  connecting,

  /// Agents on the computer can use the phone.
  attached,

  /// Lost or failed for a reason that may pass; the next attempt is scheduled.
  waiting,

  /// Needs the person (host key, Node missing, another phone took over, pairing refused).
  failed,
}

enum PhoneLinkErrorKind {
  ssh,
  hostKeyUnknown,
  hostKeyChanged,
  noShell,
  nodeMissing,
  nodeOld,
  install,
  start,
  refused,
  replaced,
  lost,

  /// The network: no address of a paired computer answered.
  unreachable,

  /// The network: the computer no longer accepts this phone (unpaired there, or a new identity).
  notPaired,
}

class PhoneLinkError implements Exception {
  const PhoneLinkError(this.kind, {this.message, this.detail, this.retryable = false});

  final PhoneLinkErrorKind kind;

  /// From the SSH layer when it had a sentence of its own (already localized).
  final String? message;
  final String? detail;
  final bool retryable;

  @override
  String toString() => 'PhoneLinkError(${kind.name}${detail == null ? '' : ': $detail'})';
}

class PhoneLinkStatus {
  const PhoneLinkStatus(this.phase, {this.error, this.computer, this.agents = const [], this.caps = const []});

  final PhoneLinkPhase phase;
  final PhoneLinkError? error;

  /// The computer's own host name, from the daemon (display only).
  final String? computer;

  /// What the agents connected now call themselves, one per connection.
  final List<String> agents;

  /// The attached daemon's capabilities (`agents.acp.v1` makes it a cockpit).
  final List<String> caps;

  bool get attached => phase == PhoneLinkPhase.attached;
}

/// One way to reach a computer's dsh-go-link: what an attach attempt opens.
class LinkConnection {
  const LinkConnection({
    required this.input,
    required this.output,
    required this.close,
    this.token = '',
    this.pairingSecret,
    this.done,
  });

  final Stream<List<int>> input;
  final StreamSink<List<int>> output;
  final void Function() close;
  final String token;
  final String? pairingSecret;

  /// Completes when the carrier underneath (the SSH connection) is gone.
  final Future<void>? done;
}

abstract class LinkDialer {
  /// Namespaces the phone-side channel ids and task owners: `ssh:<host id>`, `lan:<computer id>`.
  String get scope;

  /// What the phone shows for this computer.
  String get label;

  Future<LinkConnection> dial();

  /// Registration snippets without a live link (null: only over the link).
  Future<List<AgentSetup>> agentSetupOffline() => Future.error(const PhoneLinkError(PhoneLinkErrorKind.lost));

  /// The first attach worked (a pairing secret is spent).
  void attached() {}
}

/// An SSH host: its own SSH connection (the pinned key required, never asked here), dsh-go-link
/// installed and started over it, the daemon's loopback port tunnelled.
class SshLinkDialer extends LinkDialer {
  SshLinkDialer({
    required this.config,
    required this.loadSecrets,
    required this.transportFactory,
    required this.script,
    this.environment = const {},
  });

  /// Takes a rename at the next attach; a new address or login needs a new link.
  SshHostConfig config;
  final Future<SshSecrets> Function() loadSecrets;
  final SshTransportFactory transportFactory;

  /// The `dsh-go-link.cjs` this app ships (an asset).
  final Future<String> Function() script;
  final Map<String, String> environment;

  @override
  String get scope => 'ssh:${config.id}';

  @override
  String get label => config.name;

  Future<LinkBootstrap> _bootstrap(SshTransport transport) async =>
      LinkBootstrap(transport, script: await script(), environment: environment);

  Future<SshTransport> connect() async {
    var verdict = HostKeyVerdict.trusted;
    try {
      return await transportFactory(SshConnectParams.of(config, await loadSecrets()), (key) {
        verdict = checkHostKey(config, key);
        return verdict == HostKeyVerdict.trusted;
      });
    } catch (e) {
      // The key is confirmed only on the host's own page; never trust a new one from here.
      if (verdict == HostKeyVerdict.unknown) throw const PhoneLinkError(PhoneLinkErrorKind.hostKeyUnknown);
      if (verdict == HostKeyVerdict.mismatch) throw const PhoneLinkError(PhoneLinkErrorKind.hostKeyChanged);
      if (e is HostLinkError) {
        throw PhoneLinkError(PhoneLinkErrorKind.ssh, message: e.message, detail: e.detail, retryable: e.retryable);
      }
      throw PhoneLinkError(PhoneLinkErrorKind.ssh, detail: '$e', retryable: true);
    }
  }

  @override
  Future<LinkConnection> dial() async {
    final transport = await connect();
    try {
      final LinkEndpoint endpoint;
      try {
        endpoint = await (await _bootstrap(transport)).ensure();
      } on LinkBootstrapError catch (e) {
        throw PhoneLinkError(switch (e.failure) {
          LinkBootstrapFailure.noShell => PhoneLinkErrorKind.noShell,
          LinkBootstrapFailure.nodeMissing => PhoneLinkErrorKind.nodeMissing,
          LinkBootstrapFailure.nodeOld => PhoneLinkErrorKind.nodeOld,
          LinkBootstrapFailure.install => PhoneLinkErrorKind.install,
          LinkBootstrapFailure.start => PhoneLinkErrorKind.start,
        }, detail: e.detail);
      } on HostLinkError catch (e) {
        throw PhoneLinkError(PhoneLinkErrorKind.ssh, message: e.message, detail: e.detail, retryable: e.retryable);
      }
      final TunnelChannel tunnel;
      try {
        tunnel = await transport.openTunnel('127.0.0.1', endpoint.port);
      } catch (e) {
        throw PhoneLinkError(PhoneLinkErrorKind.start, detail: '$e', retryable: true);
      }
      return LinkConnection(
        input: tunnel.stream,
        output: tunnel.sink,
        token: endpoint.token,
        close: () {
          tunnel.destroy();
          transport.close();
        },
        done: transport.done,
      );
    } catch (_) {
      transport.close();
      rethrow;
    }
  }

  @override
  Future<List<AgentSetup>> agentSetupOffline() async {
    final transport = await connect();
    try {
      final b = await _bootstrap(transport);
      // `ensure` installs the script `config` runs from.
      await b.ensure();
      return await b.agentSetup();
    } finally {
      transport.close();
    }
  }
}

/// A computer paired over the network: TCP to its addresses, Noise IK against its pinned key.
class LanLinkDialer extends LinkDialer {
  LanLinkDialer({required this.computer, required this.identity, this.pairingSecret});

  LanComputer computer;
  final Future<LinkIdentity> Function() identity;

  /// The pairing link's one-time secret, until the first attach spends it.
  String? pairingSecret;

  @override
  String get scope => 'lan:${computer.id}';

  @override
  String get label => computer.name;

  @override
  void attached() => pairingSecret = null;

  @override
  Future<LinkConnection> dial() async {
    final NoiseLinkStream stream;
    try {
      stream = await NoiseLinkStream.dial(computer, await identity());
    } on LanLinkError catch (e) {
      throw switch (e.code) {
        'key_mismatch' => PhoneLinkError(PhoneLinkErrorKind.hostKeyChanged, detail: e.detail),
        _ => PhoneLinkError(PhoneLinkErrorKind.unreachable, detail: e.detail, retryable: true),
      };
    }
    return LinkConnection(input: stream.input, output: stream.output, close: stream.close, pairingSecret: pairingSecret);
  }
}

/// One computer whose agents may use this phone, through a [LinkDialer]; the attached
/// [LinkSession] relayed to the phone. Reconnects with backoff; stops for good when another phone
/// takes over or the person has to fix something. Also the way in for the agent cockpit:
/// [session] while attached, and the agent sessions its phone channels belong to.
class PhoneLink {
  PhoneLink({
    required this.dialer,
    required this.remote,
    required this.phone,
    Stream<void>? kicks,
    Backoff? backoff,
  }) : _backoff = backoff ?? Backoff(max: const Duration(seconds: 60), maxAttempts: null) {
    _kickSub = kicks?.listen((_) => _delay.skip());
  }

  final LinkDialer dialer;
  final PhoneLinkRemote remote;
  final LinkPhone phone;
  final Backoff _backoff;
  final _delay = InterruptibleDelay();
  final _statuses = StreamController<PhoneLinkStatus>.broadcast(sync: true);
  final _sessions = StreamController<LinkSession?>.broadcast(sync: true);
  StreamSubscription<void>? _kickSub;
  PhoneLinkStatus _status = const PhoneLinkStatus(PhoneLinkPhase.connecting);
  LinkConnection? _connection;
  LinkSession? _session;
  final _agents = <String, String>{};

  /// Phone-side channel id → the agent session it was opened for (cockpit sessions only).
  final _bound = <String, String>{};
  bool _running = false;
  bool _closed = false;

  PhoneLinkStatus get status => _status;

  Stream<PhoneLinkStatus> get statuses => _statuses.stream;

  /// The attached session (null while not attached).
  LinkSession? get session => _session;

  /// Each attach's session, and null when it ends.
  Stream<LinkSession?> get sessions => _sessions.stream;

  /// Starts the attach loop (again, after [PhoneLinkPhase.failed]).
  void start() {
    if (_closed || _running) return;
    _running = true;
    _backoff.reset();
    unawaited(_loop());
  }

  /// Skips the wait before the next attempt.
  void retry() {
    if (_running) {
      _delay.skip();
    } else {
      start();
    }
  }

  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    _delay.skip();
    await _kickSub?.cancel();
    await _session?.close();
    _connection?.close();
    await _statuses.close();
    await _sessions.close();
  }

  /// Per-agent registration snippets from the computer: over the link when attached, else over SSH.
  Future<List<AgentSetup>> agentSetup() async {
    final s = _session;
    if (s != null && !s.isClosed && s.host.has('rpc.v1')) {
      final r = await s.call('setup.agents');
      final agents = r is Map ? r['agents'] : null;
      return [
        if (agents is List)
          for (final a in agents) ?AgentSetup.fromJson(a),
      ];
    }
    return dialer.agentSetupOffline();
  }

  /// Whether [key] (a phone task owner) is one of this link's channels.
  bool owns(String key) => key.startsWith('${dialer.scope}/');

  /// The person stopped the phone task [key] owns: when it belongs to an agent session started from
  /// the phone, that session's turn is cancelled too (a plain MCP agent only hears it from its tools).
  Future<void> stopOwner(String key) async {
    final id = _bound[key];
    final s = _session;
    if (id == null || s == null || s.isClosed) return;
    try {
      await s.call('sessions.cancel', {'id': id});
    } on LinkCallError {
      // Gone already.
    }
  }

  void _emit(PhoneLinkStatus next) {
    if (_closed) return;
    _status = next;
    _statuses.add(next);
  }

  Future<void> _loop() async {
    try {
      while (!_closed) {
        _emit(PhoneLinkStatus(PhoneLinkPhase.connecting, error: _status.error));
        PhoneLinkError? error;
        try {
          final end = await _attachOnce();
          if (end.replaced) {
            _emit(const PhoneLinkStatus(PhoneLinkPhase.failed, error: PhoneLinkError(PhoneLinkErrorKind.replaced)));
            return;
          }
          error = const PhoneLinkError(PhoneLinkErrorKind.lost, retryable: true);
        } on PhoneLinkError catch (e) {
          error = e;
        } catch (e) {
          error = PhoneLinkError(PhoneLinkErrorKind.lost, detail: '$e', retryable: true);
        }
        if (_closed) return;
        if (!error.retryable) {
          _emit(PhoneLinkStatus(PhoneLinkPhase.failed, error: error));
          return;
        }
        _emit(PhoneLinkStatus(PhoneLinkPhase.waiting, error: error));
        await _delay.wait(_backoff.next());
      }
    } finally {
      _running = false;
    }
  }

  /// One attachment, from dialing to the link's end. Throws [PhoneLinkError] before it is attached.
  Future<LinkEnd> _attachOnce() async {
    final connection = _connection = await dialer.dial();
    LinkMcpRouter? router;
    StreamSubscription<LinkNotice>? notices;
    try {
      final LinkSession session;
      try {
        session = _session = await LinkSession.open(
          input: connection.input,
          output: connection.output,
          token: connection.token,
          phone: phone,
          mcp: await remote.catalog(),
          pairingSecret: connection.pairingSecret,
          onClose: connection.close,
        );
      } on LinkRefused catch (e) {
        if (e.code == 'not_paired') throw const PhoneLinkError(PhoneLinkErrorKind.notPaired);
        throw PhoneLinkError(PhoneLinkErrorKind.refused, detail: e.code, retryable: true);
      } on TimeoutException {
        throw const PhoneLinkError(PhoneLinkErrorKind.refused, detail: 'timeout', retryable: true);
      }
      dialer.attached();
      _agents.clear();
      _bound.clear();
      // Channel ids are the daemon's own (m1, m2, …): namespaced, so two computers never share one.
      String onPhone(String ch) => '${dialer.scope}/$ch';
      router = LinkMcpRouter(
        session,
        open: (ch, origin) async {
          await remote.open(onPhone(ch), key: onPhone(ch), client: origin.display, host: dialer.label);
          _agents[ch] = origin.display ?? '?';
          if (origin.session case final id?) _bound[onPhone(ch)] = id;
          _emitAttached(session);
        },
        line: (ch, line) => remote.line(onPhone(ch), line),
        close: (ch) async {
          _bound.remove(onPhone(ch));
          await remote.close(onPhone(ch));
          if (_agents.remove(ch) != null && !session.isClosed) _emitAttached(session);
        },
      );
      // An agent session's turn ended: the phone task its agent owns ends too (overlay closes).
      notices = session.notices.listen((n) {
        if (n.name != 'turn_end' || n.data is! Map) return;
        final id = (n.data as Map)['id'];
        for (final e in _bound.entries.where((e) => e.value == id).toList()) {
          unawaited(remote.finish(e.key).catchError((Object _) {}));
        }
      });
      _backoff.reset();
      _emitAttached(session);
      _sessions.add(session);
      if (connection.done case final done?) unawaited(done.then((_) => session.close()));
      return await session.done;
    } finally {
      await notices?.cancel();
      await router?.dispose();
      _agents.clear();
      _bound.clear();
      if (_session != null) {
        _session = null;
        if (!_sessions.isClosed) _sessions.add(null);
      }
      _connection = null;
      connection.close();
    }
  }

  void _emitAttached(LinkSession session) => _emit(
    PhoneLinkStatus(
      PhoneLinkPhase.attached,
      computer: session.host.name,
      agents: List.unmodifiable(_agents.values),
      caps: session.host.caps,
    ),
  );
}
