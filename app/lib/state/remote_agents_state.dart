// The phone as the cockpit (docs/design/remote-agents.md §5): Claude Code, Codex, Antigravity,
// OpenCode or Gemini CLI sessions that dsh-go-link runs on an attached computer (`agents.acp.v1`),
// listed per computer, and one session's chat. Sessions live on the computer: the phone only
// watches them, catching up by sequence number after a reconnect, and they keep running while the
// phone is away. With `agents.acp.v2` the phone also sets each agent's environment, turns its
// bypass on or off, and resumes a folder's earlier sessions.

import 'dart:async';
import 'dart:convert';

import 'package:dsh_link/dsh_link.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../remote/link/phone_link.dart';
import '../remote/secret_store.dart';
import 'hosts_state.dart';
import 'phone_link_state.dart';

/// An agent's environment variables on one computer: kept in the secret store (they often hold
/// keys), sent with every request that may start that agent. The computer keeps them in memory.
class AgentEnvStore {
  AgentEnvStore(this._secrets);

  final SecretStore _secrets;

  static String _key(String computer, String agent) => 'agents.env.$computer.$agent';

  /// A shell variable name (what the computer accepts).
  static final name = RegExp(r'^[A-Za-z_][A-Za-z0-9_]*$');

  Future<Map<String, String>> read(String computer, String agent) async {
    try {
      final raw = await _secrets.read(_key(computer, agent));
      final v = raw == null ? null : jsonDecode(raw);
      if (v is! Map) return const {};
      return {
        for (final e in v.entries)
          if (e.key is String && e.value is String && name.hasMatch(e.key as String)) e.key as String: e.value as String,
      };
    } on Object {
      return const {};
    }
  }

  Future<void> write(String computer, String agent, Map<String, String> env) => env.isEmpty
      ? _secrets.delete(_key(computer, agent))
      : _secrets.write(_key(computer, agent), jsonEncode(env));
}

final agentEnvStoreProvider = Provider<AgentEnvStore>((ref) => AgentEnvStore(ref.watch(secretStoreProvider)));

/// One attached computer that can run agents.
class AgentComputer {
  const AgentComputer({
    required this.id,
    required this.name,
    this.agents = const [],
    this.sessions = const [],
    this.loading = true,
  });

  final String id;
  final String name;
  final List<AgentKind> agents;

  /// Newest activity first.
  final List<AgentSessionInfo> sessions;
  final bool loading;

  List<AgentKind> get available => [for (final a in agents) if (a.available) a];

  AgentComputer copyWith({List<AgentKind>? agents, List<AgentSessionInfo>? sessions, bool? loading}) => AgentComputer(
    id: id,
    name: name,
    agents: agents ?? this.agents,
    sessions: sessions ?? this.sessions,
    loading: loading ?? this.loading,
  );
}

List<AgentSessionInfo> _sorted(Iterable<AgentSessionInfo> s) => s.where((x) => x.status != 'closed').toList()
  ..sort((a, b) => (b.updatedAt ?? DateTime(0)).compareTo(a.updatedAt ?? DateTime(0)));

/// Attached computers with agents, by computer id, kept current from the daemons' notices.
class RemoteAgentsController extends Notifier<Map<String, AgentComputer>> {
  final _watched = <String, LinkSession>{};
  final _subs = <String, StreamSubscription<LinkNotice>>{};

  @override
  Map<String, AgentComputer> build() {
    ref.onDispose(() {
      for (final s in _subs.values) {
        unawaited(s.cancel());
      }
    });
    ref.listen(phoneLinksProvider, (_, _) => _sync());
    scheduleMicrotask(_sync);
    return const {};
  }

  PhoneLink? _link(String id) => ref.read(phoneLinksProvider.notifier).link(id);

  /// The attached session of computer [id], when it runs agents.
  LinkSession? session(String id) {
    final s = _link(id)?.session;
    return s != null && !s.isClosed && s.host.has('agents.acp.v1') ? s : null;
  }

  /// Computer [id]'s daemon takes environments, bypass and earlier sessions (`agents.acp.v2`).
  bool hasV2(String id) => session(id)?.host.has('agents.acp.v2') ?? false;

  /// What every request that may start [agent] on computer [id] carries: its environment.
  Future<Map<String, Object?>> _start(String id, String agent) async =>
      hasV2(id) ? {'env': await ref.read(agentEnvStoreProvider).read(id, agent)} : const {};

  void _sync() {
    if (!ref.mounted) return;
    final statuses = ref.read(phoneLinksProvider);
    final next = <String, AgentComputer>{};
    for (final id in statuses.keys) {
      final s = session(id);
      if (s == null) continue;
      final link = _link(id)!;
      next[id] = state[id] ?? AgentComputer(id: id, name: link.dialer.label);
      if (!identical(_watched[id], s)) {
        _watched[id] = s;
        unawaited(_subs.remove(id)?.cancel());
        _subs[id] = s.notices.listen((n) => _onNotice(id, n));
        unawaited(refresh(id));
      }
    }
    for (final id in _watched.keys.toList()) {
      if (!next.containsKey(id)) {
        _watched.remove(id);
        unawaited(_subs.remove(id)?.cancel());
      }
    }
    state = next;
  }

  void _onNotice(String id, LinkNotice n) {
    if (n.name != 'sessions' || !ref.mounted) return;
    final info = AgentSessionInfo.fromJson(n.data);
    final c = state[id];
    if (info == null || c == null) return;
    state = {
      ...state,
      id: c.copyWith(sessions: _sorted([info, ...c.sessions.where((s) => s.id != info.id)])),
    };
  }

  /// Agents and sessions of computer [id], from the daemon.
  Future<void> refresh(String id) async {
    final s = session(id);
    if (s == null) return;
    try {
      final agents = await s.call('agents.list');
      final sessions = await s.call('sessions.list');
      final c = state[id];
      if (!ref.mounted || c == null) return;
      state = {
        ...state,
        id: c.copyWith(
          loading: false,
          agents: [for (final a in _list(agents, 'agents')) ?AgentKind.fromJson(a)],
          sessions: _sorted([for (final x in _list(sessions, 'sessions')) ?AgentSessionInfo.fromJson(x)]),
        ),
      };
    } on LinkCallError {
      final c = state[id];
      if (ref.mounted && c != null) state = {...state, id: c.copyWith(loading: false)};
    }
  }

  /// Starts [agent] in [cwd] on computer [id] ([bypass]: without permission prompts); the new
  /// session's id.
  Future<String> start(String id, String agent, String cwd, {bool bypass = false}) async {
    final s = session(id);
    if (s == null) throw const LinkCallError('closed');
    final r = await s.call('sessions.new', {
      'agent': agent,
      'cwd': cwd,
      ...await _start(id, agent),
      if (bypass && hasV2(id)) 'bypass': true,
    });
    return _took(id, r);
  }

  String _took(String id, Object? r) {
    final info = AgentSessionInfo.fromJson(r is Map ? r['session'] : null);
    if (info == null) throw const LinkCallError('malformed');
    _onNotice(id, LinkNotice('sessions', (r as Map)['session']));
    return info.id;
  }

  /// [agent]'s earlier sessions in [cwd] on computer [id]: the ones the computer keeps and the
  /// agent's own (started in a terminal, say). Empty from a daemon without `agents.acp.v2`.
  Future<AgentHistory> history(String id, String agent, String cwd) async {
    final s = session(id);
    if (s == null) throw const LinkCallError('closed');
    if (!hasV2(id)) return const AgentHistory();
    return AgentHistory.fromJson(await s.call('sessions.history', {'agent': agent, 'cwd': cwd, ...await _start(id, agent)}));
  }

  /// Opens [entry]: a session the computer keeps is only watched (its running turn goes on);
  /// another one becomes a session there, resumed with its history. The session's id.
  Future<String> resume(String id, String agent, String cwd, AgentHistoryEntry entry, {bool bypass = false}) async {
    if (entry.session case final kept?) return kept.id;
    final s = session(id);
    if (s == null) throw const LinkCallError('closed');
    final r = await s.call('sessions.resume', {
      'agent': agent,
      'agentSessionId': entry.agentSessionId,
      'cwd': cwd,
      'title': ?entry.title,
      ...await _start(id, agent),
      if (bypass) 'bypass': true,
    });
    return _took(id, r);
  }

  /// Folders on computer [id] (`fs.list`): its path, its parent, and the folders in it.
  Future<({String path, String? parent, List<String> dirs})> folders(String id, String? path) async {
    final s = session(id);
    if (s == null) throw const LinkCallError('closed');
    final r = await s.call('fs.list', {'path': ?path});
    final m = r is Map ? r : const {};
    return (
      path: '${m['path'] ?? ''}',
      parent: m['parent'] is String ? m['parent'] as String : null,
      dirs: [for (final d in _list(r, 'dirs')) if (d is String) d],
    );
  }
}

List<Object?> _list(Object? r, String key) => r is Map && r[key] is List ? (r[key] as List).cast<Object?>() : const [];

final remoteAgentsProvider = NotifierProvider<RemoteAgentsController, Map<String, AgentComputer>>(RemoteAgentsController.new);

/// What an agent chat page shows.
class AgentChatState {
  const AgentChatState({this.info, this.items = const [], this.loading = true, this.attached = false, this.error});

  final AgentSessionInfo? info;
  final List<AgentItem> items;
  final bool loading;

  /// The computer is attached now (sending works).
  final bool attached;

  /// The last request's failure code (`busy`, `closed`, …), for a toast.
  final String? error;

  bool get busy => info?.busy ?? false;
}

typedef AgentChatKey = ({String computer, String session});

/// One session's chat: watched while the page is open, caught up after every reconnect.
class AgentChatController extends Notifier<AgentChatState> {
  AgentChatController(this.key);

  final AgentChatKey key;
  final _transcript = AgentTranscript();
  LinkSession? _session;
  StreamSubscription<LinkNotice>? _notices;
  StreamSubscription<LinkSession?>? _sessions;

  @override
  AgentChatState build() {
    ref.onDispose(() {
      unawaited(_notices?.cancel());
      unawaited(_sessions?.cancel());
      final s = _session;
      if (s != null && !s.isClosed) unawaited(s.call('sessions.unwatch', {'id': key.session}).catchError((Object _) => null));
    });
    final link = ref.read(phoneLinksProvider.notifier).link(key.computer);
    _sessions = link?.sessions.listen(_attach);
    scheduleMicrotask(() => _attach(link?.session));
    return const AgentChatState();
  }

  void _publish({AgentSessionInfo? info, bool? loading, String? error, bool clearError = false}) {
    if (!ref.mounted) return;
    state = AgentChatState(
      info: info ?? state.info,
      items: List.unmodifiable(_transcript.items),
      loading: loading ?? state.loading,
      attached: _session != null && !_session!.isClosed,
      error: clearError ? null : (error ?? state.error),
    );
  }

  Future<void> _attach(LinkSession? s) async {
    if (!ref.mounted) return;
    unawaited(_notices?.cancel());
    _notices = null;
    _session = s != null && !s.isClosed && s.host.has('agents.acp.v1') ? s : null;
    final session = _session;
    if (session == null) return _publish(loading: false);
    _notices = session.notices.listen((n) {
      final data = n.data;
      if (data is! Map || data['id'] != key.session) return;
      if (n.name == 'session' && data['event'] is Map) {
        _transcript.apply((data['event'] as Map).cast<Object?, Object?>());
        _publish();
      } else if (n.name == 'sessions') {
        _publish(info: AgentSessionInfo.fromJson(data));
      }
    });
    try {
      final r = await session.call('sessions.watch', {'id': key.session, 'afterSeq': _transcript.lastSeq});
      final m = r is Map ? r : const {};
      // Older events than we have were dropped on the computer: start over from what is there.
      if (m['truncated'] == true) _transcript.reset();
      for (final e in _list(r, 'events')) {
        if (e is Map) _transcript.apply(e.cast<Object?, Object?>());
      }
      _publish(info: AgentSessionInfo.fromJson(m['session']), loading: false);
    } on LinkCallError catch (e) {
      _publish(loading: false, error: e.code);
    }
  }

  /// [method] for this session; [starts]: it may start the agent, so it carries the agent's
  /// environment.
  Future<bool> _call(String method, Map<String, Object?> params, {bool starts = false}) async {
    final s = _session;
    if (s == null || s.isClosed) {
      _publish(error: 'closed');
      return false;
    }
    try {
      final agent = state.info?.agent;
      final env = starts && agent != null && s.host.has('agents.acp.v2')
          ? {'env': await ref.read(agentEnvStoreProvider).read(key.computer, agent)}
          : const <String, Object?>{};
      final r = await s.call(method, {'id': key.session, ...params, ...env});
      _publish(info: r is Map ? AgentSessionInfo.fromJson(r['session']) : null, clearError: true);
      return true;
    } on LinkCallError catch (e) {
      _publish(error: e.code);
      return false;
    }
  }

  Future<bool> send(String text) => _call('sessions.prompt', {'text': text}, starts: true);

  Future<bool> cancel() => _call('sessions.cancel', const {});

  Future<bool> answer(String requestId, String? optionId) =>
      _call('sessions.permission', {'requestId': requestId, 'optionId': optionId});

  Future<bool> setMode(String modeId) => _call('sessions.mode', {'modeId': modeId}, starts: true);

  /// Bypass on or off (`agents.acp.v2`): at once for an agent with a bypass mode; one that needs
  /// arguments stops between turns and starts with or without them on the next message.
  Future<bool> setBypass(bool on) => _call('sessions.bypass', {'on': on}, starts: true);

  Future<bool> close() => _call('sessions.close', const {});
}

final agentChatProvider = NotifierProvider.autoDispose.family<AgentChatController, AgentChatState, AgentChatKey>(
  AgentChatController.new,
);
