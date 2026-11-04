import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

/// Protocol version spoken with dsh-go-link (`dshGoLink` in the hello).
const linkProtocol = 1;

/// Longest line either side sends (a screenshot result nested in a frame is a few MB).
const linkMaxLine = 16 * 1024 * 1024;

/// What the phone says about itself in the hello.
class LinkPhone {
  const LinkPhone({required this.id, required this.name, this.app});

  /// Stable per install (not a hardware id).
  final String id;
  final String name;

  /// DSH Go version.
  final String? app;

  Map<String, Object?> toJson() => {'id': id, 'name': name, 'app': ?app};
}

/// The computer, from the daemon's hello reply. [name] comes from the computer: display only.
class LinkHost {
  const LinkHost({required this.name, required this.os, required this.linkVersion, this.caps = const []});

  final String name;
  final String os;
  final String linkVersion;

  /// What the daemon offers: `phone.mcp.v1`, `rpc.v1`, `agents.acp.v1`, `lan.v1` (older daemons: none).
  final List<String> caps;

  bool has(String cap) => caps.contains(cap);
}

/// An agent connection as the daemon reports it. Names are the agent's own claims, unverified.
class LinkOrigin {
  const LinkOrigin({this.name, this.title, this.version, this.session, this.agent});

  factory LinkOrigin.fromJson(Object? v) {
    final m = v is Map ? v : const {};
    String? s(Object? x) => x is String && x.trim().isNotEmpty ? x : null;
    return LinkOrigin(
      name: s(m['name']),
      title: s(m['title']),
      version: s(m['version']),
      session: s(m['session']),
      agent: s(m['agent']),
    );
  }

  /// MCP `clientInfo.name`, e.g. `claude-code`.
  final String? name;
  final String? title;
  final String? version;

  /// The agent session the daemon started this connection for (the phone as the cockpit), if any.
  final String? session;

  /// That session's agent id (`claude-code`, `codex`, …).
  final String? agent;

  /// What to show: the title when the agent sent one, else its name.
  String? get display => title ?? name;
}

sealed class LinkEvent {
  const LinkEvent(this.ch);

  final String ch;
}

/// An agent connection was opened toward the phone ([kind] `mcp` in protocol 1).
final class ChannelOpened extends LinkEvent {
  const ChannelOpened(super.ch, this.kind, this.origin);

  final String kind;
  final LinkOrigin origin;
}

/// One JSON-RPC message from the agent.
final class ChannelData extends LinkEvent {
  const ChannelData(super.ch, this.line);

  final String line;
}

/// The agent went away, or the link ended (every open channel gets one).
final class ChannelClosed extends LinkEvent {
  const ChannelClosed(super.ch);
}

/// A daemon notice outside any channel (`{t: event}`): `sessions`, `session`, `turn_end`.
class LinkNotice {
  const LinkNotice(this.name, this.data);

  final String name;
  final Object? data;
}

/// A `call` the daemon answered with an error, or that the link's end cut short (`closed`).
class LinkCallError implements Exception {
  const LinkCallError(this.code, [this.message = '']);

  final String code;
  final String message;

  @override
  String toString() => 'LinkCallError($code${message.isEmpty ? '' : ': $message'})';
}

/// The daemon refused the hello: `bad_token`, `protocol`, `not_paired`, or a malformed reply.
class LinkRefused implements Exception {
  const LinkRefused(this.code);

  final String code;

  @override
  String toString() => 'LinkRefused($code)';
}

/// Why a link ended. `replaced` (another phone took over) and `shutdown` come from the daemon;
/// `closed` (stream ended), `silent` (no frame for too long), `error` and `local` from here.
class LinkEnd {
  const LinkEnd(this.code);

  final String code;

  /// Another phone attached to this computer: don't fight it by reconnecting.
  bool get replaced => code == 'replaced';

  @override
  String toString() => 'LinkEnd($code)';
}

/// The phone's end of one attachment to a dsh-go-link daemon over any byte stream (an SSH
/// direct-tcpip channel today). Speaks newline-delimited JSON frames; pings every
/// [pingInterval] and gives up after [silenceLimit] without a frame.
class LinkSession {
  LinkSession._(this._output, this.host, this._onClose, this.pingInterval, this.silenceLimit);

  /// Sends the hello and waits for the daemon's answer. Throws [LinkRefused] when it refuses, or a
  /// [TimeoutException]. [mcp] is the phone's tool catalog (`tools`, `instructions`, `serverInfo`).
  static Future<LinkSession> open({
    required Stream<List<int>> input,
    required StreamSink<List<int>> output,
    required String token,
    required LinkPhone phone,
    Map<String, Object?>? mcp,
    String? pairingSecret,
    void Function()? onClose,
    Duration helloTimeout = const Duration(seconds: 10),
    Duration pingInterval = const Duration(seconds: 20),
    Duration silenceLimit = const Duration(seconds: 50),
  }) async {
    final hello = Completer<Object?>();
    LinkSession? session;
    final early = <String>[];
    late final StreamSubscription<String> sub;
    sub = splitLines(input).listen(
      (line) {
        final s = session;
        if (s != null) return s._onLine(line);
        if (!hello.isCompleted) return hello.complete(_decode(line));
        // Frames right behind the reply, before `open` returned.
        early.add(line);
      },
      onError: (Object e) {
        if (!hello.isCompleted) return hello.completeError(e);
        session?._end('error');
      },
      onDone: () {
        if (!hello.isCompleted) return hello.completeError(const LinkRefused('closed'));
        session?._end('closed');
      },
      cancelOnError: true,
    );
    void send(Object v) => output.add(utf8.encode('${jsonEncode(v)}\n'));
    try {
      send({'dshGoLink': linkProtocol, 'token': token, 'phone': phone.toJson(), 'mcp': ?mcp, 'pair': ?pairingSecret});
      final reply = await hello.future.timeout(helloTimeout);
      if (reply is! Map || reply['ok'] != true) {
        throw LinkRefused(reply is Map && reply['code'] is String ? reply['code'] as String : 'malformed');
      }
      final h = reply['host'] is Map ? reply['host'] as Map : const {};
      final l = reply['link'] is Map ? reply['link'] as Map : const {};
      final caps = reply['caps'] is List
          ? [
              for (final c in reply['caps'] as List)
                if (c is String) c,
            ]
          : const <String>[];
      final s = session = LinkSession._(
        output,
        LinkHost(
          name: h['name'] is String ? h['name'] as String : '',
          os: h['os'] is String ? h['os'] as String : '',
          linkVersion: l['version'] is String ? l['version'] as String : '',
          caps: caps,
        ),
        onClose,
        pingInterval,
        silenceLimit,
      );
      s._sub = sub;
      s._start();
      // Delivered after the caller had a chance to listen to [events].
      if (early.isNotEmpty) scheduleMicrotask(() => early.forEach(s._onLine));
      return s;
    } catch (_) {
      await sub.cancel();
      onClose?.call();
      rethrow;
    }
  }

  final StreamSink<List<int>> _output;
  final void Function()? _onClose;
  final Duration pingInterval;
  final Duration silenceLimit;

  /// The computer this phone is attached to.
  final LinkHost host;

  StreamSubscription<String>? _sub;
  final _events = StreamController<LinkEvent>();
  final _notices = StreamController<LinkNotice>.broadcast();
  final _done = Completer<LinkEnd>();
  final _open = <String>{};
  final _calls = <int, Completer<Object?>>{};
  var _nextCall = 1;
  Timer? _ping;
  Timer? _silence;

  /// Agent channels and their messages. Single subscription; every open channel is closed before it ends.
  Stream<LinkEvent> get events => _events.stream;

  /// Daemon notices (agent sessions); any number of listeners.
  Stream<LinkNotice> get notices => _notices.stream;

  /// Completes once, with why the link ended.
  Future<LinkEnd> get done => _done.future;

  /// A request to the daemon (`rpc.v1`): its result, or a [LinkCallError]. Pending calls fail with
  /// `closed` when the link ends.
  Future<Object?> call(String method, [Map<String, Object?> params = const {}]) {
    if (isClosed) return Future.error(const LinkCallError('closed'));
    final id = _nextCall++;
    final c = _calls[id] = Completer<Object?>();
    _send({'t': 'call', 'id': id, 'method': method, 'params': params});
    return c.future;
  }

  bool get isClosed => _done.isCompleted;

  /// Channels open right now.
  Set<String> get channels => Set.unmodifiable(_open);

  void _start() {
    _ping = Timer.periodic(pingInterval, (_) => _send({'t': 'ping'}));
    _heard();
  }

  void _heard() {
    _silence?.cancel();
    _silence = Timer(silenceLimit, () => _end('silent'));
  }

  void _onLine(String line) {
    if (isClosed) return;
    _heard();
    final frame = _decode(line);
    if (frame is! Map) return;
    final type = frame['t'];
    if (type == 'ping') return _send({'t': 'pong'});
    if (type == 'result') {
      final c = frame['id'] is int ? _calls.remove(frame['id']) : null;
      if (c == null) return;
      final error = frame['error'];
      if (error is Map) {
        c.completeError(LinkCallError('${error['code'] ?? 'failed'}', '${error['message'] ?? ''}'));
      } else {
        c.complete(frame['result']);
      }
      return;
    }
    if (type == 'event') {
      final name = frame['name'];
      if (name is String) _notices.add(LinkNotice(name, frame['data']));
      return;
    }
    if (type == 'bye') return _end(frame['code'] is String ? frame['code'] as String : 'bye', sayBye: false);
    final ch = frame['ch'];
    if (ch is! String) return;
    switch (type) {
      case 'open':
        _open.add(ch);
        final kind = frame['kind'];
        _events.add(ChannelOpened(ch, kind is String ? kind : 'mcp', LinkOrigin.fromJson(frame['origin'])));
      case 'data':
        final data = frame['line'];
        if (data is String && _open.contains(ch)) _events.add(ChannelData(ch, data));
      case 'close':
        if (_open.remove(ch)) _events.add(ChannelClosed(ch));
    }
  }

  /// One JSON-RPC message to the agent on channel [ch].
  void send(String ch, String line) {
    if (_open.contains(ch)) _send({'t': 'data', 'ch': ch, 'line': line});
  }

  /// Closes [ch] from this side; the daemon answers its pending requests with [message].
  void closeChannel(String ch, {String? message}) {
    if (!_open.remove(ch)) return;
    _send({'t': 'close', 'ch': ch, 'message': ?message});
    _events.add(ChannelClosed(ch));
  }

  /// Leaves politely (`bye`) and ends with `local`.
  Future<LinkEnd> close() {
    _end('local');
    return done;
  }

  void _send(Object frame) {
    if (isClosed) return;
    try {
      _output.add(utf8.encode('${jsonEncode(frame)}\n'));
    } catch (_) {
      // The sink closed under us; the input side ends the session.
    }
  }

  void _end(String code, {bool sayBye = true}) {
    if (isClosed) return;
    if (sayBye && code == 'local') _send({'t': 'bye'});
    _done.complete(LinkEnd(code));
    _ping?.cancel();
    _silence?.cancel();
    for (final ch in _open) {
      _events.add(ChannelClosed(ch));
    }
    _open.clear();
    for (final c in _calls.values) {
      c.completeError(const LinkCallError('closed'));
    }
    _calls.clear();
    unawaited(_events.close());
    unawaited(_notices.close());
    unawaited(_sub?.cancel());
    _onClose?.call();
  }
}

Object? _decode(String line) {
  try {
    return jsonDecode(line);
  } on FormatException {
    return null;
  }
}

/// UTF-8 lines ending in `\n` (a trailing `\r` dropped). A line over [max] bytes is an error.
/// Cancelling the lines cancels [input] at once (an `async*` would wait for its next chunk).
Stream<String> splitLines(Stream<List<int>> input, {int max = linkMaxLine}) {
  final buf = BytesBuilder(copy: false);
  StreamSubscription<List<int>>? sub;
  late final StreamController<String> out;
  void onChunk(List<int> chunk) {
    var start = 0;
    for (var i = 0; i < chunk.length; i++) {
      if (chunk[i] != 10) continue;
      if (buf.length + i - start > max) return _tooLong(out, sub);
      buf.add(chunk.sublist(start, i));
      var line = utf8.decode(buf.takeBytes(), allowMalformed: true);
      if (line.endsWith('\r')) line = line.substring(0, line.length - 1);
      out.add(line);
      start = i + 1;
    }
    if (start < chunk.length) {
      if (buf.length + chunk.length - start > max) return _tooLong(out, sub);
      buf.add(chunk.sublist(start));
    }
  }

  out = StreamController<String>(
    onListen: () => sub = input.listen(onChunk, onError: out.addError, onDone: out.close),
    onPause: () => sub?.pause(),
    onResume: () => sub?.resume(),
    onCancel: () => sub?.cancel(),
  );
  return out.stream;
}

void _tooLong(StreamController<String> out, StreamSubscription<List<int>>? sub) {
  if (out.isClosed) return;
  out.addError(const FormatException('line too long'));
  unawaited(sub?.cancel());
  unawaited(out.close());
}
