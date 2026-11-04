import 'dart:async';
import 'dart:convert';

import 'link_session.dart';

/// Opens a phone-side dispatcher for an agent channel.
typedef RemoteOpen = Future<void> Function(String ch, LinkOrigin origin);

/// Hands one JSON-RPC line to the phone; its answer (null: nothing to send). May take minutes
/// (a `handoff` waits for the person).
typedef RemoteLine = Future<String?> Function(String ch, String line);

/// The agent channel is gone.
typedef RemoteClose = Future<void> Function(String ch);

/// Relays a [LinkSession]'s MCP channels to the phone: `open` before the first line of a channel,
/// every request answered (a failure in the relay becomes an error result, never silence), and
/// `close` for every channel opened, including those still open when the link ends.
class LinkMcpRouter {
  LinkMcpRouter(this.session, {required RemoteOpen open, required RemoteLine line, required RemoteClose close})
    : _open = open,
      _line = line,
      _close = close {
    _sub = session.events.listen(_on, onDone: _closeAll);
  }

  final LinkSession session;
  final RemoteOpen _open;
  final RemoteLine _line;
  final RemoteClose _close;
  late final StreamSubscription<LinkEvent> _sub;
  final _ready = <String, Future<bool>>{};

  /// Agent channels routed to the phone right now.
  int get channels => _ready.length;

  void _on(LinkEvent e) {
    switch (e) {
      case ChannelOpened(:final ch, :final kind, :final origin):
        if (kind != 'mcp') {
          session.closeChannel(ch, message: 'unsupported channel kind: $kind');
          return;
        }
        _ready[ch] = _open(ch, origin).then((_) => true, onError: (Object _) => false);
      case ChannelData(:final ch, :final line):
        final ready = _ready[ch];
        if (ready != null) unawaited(_relay(ch, ready, line));
      case ChannelClosed(:final ch):
        final ready = _ready.remove(ch);
        if (ready != null) unawaited(ready.then((ok) => ok ? _close(ch) : null).catchError((Object _) {}));
    }
  }

  Future<void> _relay(String ch, Future<bool> ready, String line) async {
    String? reply;
    try {
      reply = await ready ? await _line(ch, line) : mcpFailure(line, 'The phone could not open this connection.');
    } catch (e) {
      reply = mcpFailure(line, 'The phone failed to handle this call ($e).');
    }
    if (reply != null) session.send(ch, reply);
  }

  void _closeAll() {
    for (final ch in _ready.keys.toList()) {
      final ready = _ready.remove(ch)!;
      unawaited(ready.then((ok) => ok ? _close(ch) : null).catchError((Object _) {}));
    }
  }

  Future<void> dispose() async {
    await _sub.cancel();
    _closeAll();
  }
}

/// An answer for a request the phone could not handle: a tool error for `tools/call` (agents show
/// those to the model), a JSON-RPC error otherwise; null for notifications and garbage.
String? mcpFailure(String line, String text) {
  final Object? msg;
  try {
    msg = jsonDecode(line);
  } on FormatException {
    return null;
  }
  if (msg is! Map || msg['method'] is! String || !msg.containsKey('id') || msg['id'] == null) return null;
  final id = msg['id'];
  if (msg['method'] == 'tools/call') {
    return jsonEncode({
      'jsonrpc': '2.0',
      'id': id,
      'result': {
        'content': [
          {'type': 'text', 'text': '[PHONE_ERROR] $text Call `screen` before retrying.'},
        ],
        'isError': true,
      },
    });
  }
  return jsonEncode({
    'jsonrpc': '2.0',
    'id': id,
    'error': {'code': -32603, 'message': text},
  });
}
