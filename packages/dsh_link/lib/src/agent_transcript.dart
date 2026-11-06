/// The phone as the cockpit (`agents.acp.v1`): agent sessions as the daemon reports them, and a
/// reducer from a session's event log (ACP `session/update`s plus the daemon's own events) to the
/// items a chat page shows. Replaying the same events is harmless: each applies once, by `seq`.
library;

String? _s(Object? v) => v is String && v.isNotEmpty ? v : null;

int _i(Object? v) => v is num ? v.toInt() : 0;

Map<Object?, Object?> _m(Object? v) => v is Map ? v.cast<Object?, Object?>() : const {};

List<Object?> _l(Object? v) => v is List ? v.cast<Object?>() : const [];

/// How an agent runs without asking for permission (`agents.list`, `agents.acp.v2`).
enum AgentBypass {
  /// One of its modes: switched at any time.
  mode,

  /// Arguments it starts with: switching restarts it, between turns only.
  restart,
}

/// An agent the computer can run (`agents.list`).
class AgentKind {
  const AgentKind({required this.id, required this.name, required this.available, this.bypass});

  static AgentKind? fromJson(Object? v) {
    final m = _m(v);
    final id = _s(m['id']);
    if (id == null) return null;
    return AgentKind(
      id: id,
      name: _s(m['name']) ?? id,
      available: m['available'] == true,
      bypass: switch (m['bypass']) {
        'mode' => AgentBypass.mode,
        'restart' => AgentBypass.restart,
        _ => null,
      },
    );
  }

  final String id;
  final String name;

  /// Installed on the computer (the agent's CLI and its ACP command were found).
  final bool available;

  /// Null: the agent has no way to skip permission requests (or the daemon predates it).
  final AgentBypass? bypass;
}

class AgentMode {
  const AgentMode(this.id, this.name, [this.description]);

  final String id;
  final String name;
  final String? description;
}

/// One session (`sessions.list`, `sessions` notices).
class AgentSessionInfo {
  const AgentSessionInfo({
    required this.id,
    required this.agent,
    required this.agentName,
    required this.cwd,
    this.title,
    this.updatedAt,
    this.status = 'stopped',
    this.seq = 0,
    this.modes = const [],
    this.mode,
    this.pending = const [],
    this.bypass = false,
    this.agentSessionId,
  });

  static AgentSessionInfo? fromJson(Object? v) {
    final m = _m(v);
    final id = _s(m['id']);
    if (id == null) return null;
    final modes = _m(m['modes']);
    return AgentSessionInfo(
      id: id,
      agent: _s(m['agent']) ?? '',
      agentName: _s(m['agentName']) ?? _s(m['agent']) ?? '',
      cwd: _s(m['cwd']) ?? '',
      title: _s(m['title']),
      updatedAt: DateTime.tryParse(_s(m['updatedAt']) ?? '')?.toLocal(),
      status: _s(m['status']) ?? 'stopped',
      seq: _i(m['seq']),
      modes: [
        for (final x in _l(modes['availableModes']))
          if (_s(_m(x)['id']) case final id?) AgentMode(id, _s(_m(x)['name']) ?? id, _s(_m(x)['description'])),
      ],
      mode: _s(modes['currentModeId']),
      pending: [for (final p in _l(m['pending'])) ?_s(p)],
      bypass: m['bypass'] == true,
      agentSessionId: _s(m['agentSessionId']),
    );
  }

  final String id;
  final String agent;
  final String agentName;
  final String cwd;
  final String? title;
  final DateTime? updatedAt;

  /// `starting`, `idle`, `running`, `stopped` (no process; resumes on the next prompt), `closed`.
  final String status;
  final int seq;
  final List<AgentMode> modes;
  final String? mode;

  /// Permission requests waiting for the person.
  final List<String> pending;

  /// The agent runs without asking (its bypass mode, or started with its bypass arguments), as
  /// the daemon last saw the agent confirm it.
  final bool bypass;

  /// The agent's own id for the session (what its session list shows).
  final String? agentSessionId;

  bool get busy => status == 'running' || status == 'starting';

  /// The folder's last part, for a subtitle.
  String get folder {
    final parts = cwd.split(RegExp(r'[/\\]')).where((p) => p.isNotEmpty);
    return parts.isEmpty ? cwd : parts.last;
  }
}

/// One of a folder's earlier sessions of an agent (`sessions.history`): one the daemon keeps
/// ([session], opened as it is), or one from the agent's own list (started in a terminal, or here
/// before it was ended), resumed with `sessions.resume`.
class AgentHistoryEntry {
  const AgentHistoryEntry({this.agentSessionId, this.title, this.updatedAt, this.session});

  static AgentHistoryEntry? fromJson(Object? v) {
    final m = _m(v);
    final session = AgentSessionInfo.fromJson(m['session']);
    final agentSessionId = _s(m['agentSessionId']);
    if (session == null && agentSessionId == null) return null;
    return AgentHistoryEntry(
      agentSessionId: agentSessionId,
      title: _s(m['title']),
      updatedAt: DateTime.tryParse(_s(m['updatedAt']) ?? '')?.toLocal(),
      session: session,
    );
  }

  final String? agentSessionId;
  final String? title;
  final DateTime? updatedAt;

  /// Kept by the daemon: opening it only watches (a running turn goes on).
  final AgentSessionInfo? session;
}

/// A folder's earlier sessions of an agent (`sessions.history`).
class AgentHistory {
  const AgentHistory({this.entries = const [], this.listed = false, this.canLoad = false, this.error});

  static AgentHistory fromJson(Object? v) {
    final m = _m(v);
    return AgentHistory(
      entries: [for (final e in _l(m['sessions'])) ?AgentHistoryEntry.fromJson(e)],
      listed: m['listed'] == true,
      canLoad: m['canLoad'] == true,
      error: _s(m['error']),
    );
  }

  final List<AgentHistoryEntry> entries;

  /// The agent listed its own sessions (otherwise only the daemon's are here).
  final bool listed;

  /// The agent can reopen its own sessions (`session/load`).
  final bool canLoad;

  /// Why the agent's list is missing (`timeout`, `spawn_failed`, …).
  final String? error;
}

sealed class AgentItem {
  const AgentItem();

  /// Stable across rebuilds, for list diffing.
  String get key;
}

final class AgentUserItem extends AgentItem {
  const AgentUserItem(this.seq, this.text, {this.images = 0});

  final int seq;
  final String text;
  final int images;

  @override
  String get key => 'u$seq';
}

/// The agent's answer, or its thinking ([thought]), as it streams.
final class AgentTextItem extends AgentItem {
  const AgentTextItem(this.seq, this.text, {this.thought = false, this.streaming = false});

  final int seq;
  final String text;
  final bool thought;
  final bool streaming;

  AgentTextItem _plus(String more, {required bool streaming}) =>
      AgentTextItem(seq, text + more, thought: thought, streaming: streaming);

  @override
  String get key => '${thought ? 'th' : 'a'}$seq';
}

sealed class AgentToolContent {
  const AgentToolContent();
}

final class AgentToolText extends AgentToolContent {
  const AgentToolText(this.text);

  final String text;
}

final class AgentToolDiff extends AgentToolContent {
  const AgentToolDiff(this.path, this.oldText, this.newText);

  final String path;
  final String? oldText;
  final String newText;
}

final class AgentToolTerminal extends AgentToolContent {
  const AgentToolTerminal(this.terminalId);

  final String terminalId;
}

/// A tool call: `pending`, `in_progress`, `completed`, `failed`.
final class AgentToolItem extends AgentItem {
  const AgentToolItem({
    required this.id,
    required this.title,
    this.kind,
    this.status = 'pending',
    this.content = const [],
    this.locations = const [],
  });

  final String id;
  final String title;

  /// `read`, `edit`, `delete`, `move`, `search`, `execute`, `think`, `fetch`, `other`.
  final String? kind;
  final String status;
  final List<AgentToolContent> content;
  final List<String> locations;

  bool get running => status == 'pending' || status == 'in_progress';

  AgentToolItem merge(Map<Object?, Object?> u) => AgentToolItem(
    id: id,
    title: _s(u['title']) ?? title,
    kind: _s(u['kind']) ?? kind,
    status: _s(u['status']) ?? status,
    content: u.containsKey('content') ? _content(u['content']) : content,
    locations: u.containsKey('locations') ? _locations(u['locations']) : locations,
  );

  @override
  String get key => 't$id';
}

class AgentPlanEntry {
  const AgentPlanEntry(this.content, this.status);

  final String content;

  /// `pending`, `in_progress`, `completed`.
  final String status;
}

final class AgentPlanItem extends AgentItem {
  const AgentPlanItem(this.seq, this.entries);

  final int seq;
  final List<AgentPlanEntry> entries;

  @override
  String get key => 'p$seq';
}

class AgentPermissionOption {
  const AgentPermissionOption(this.optionId, this.name, this.kind);

  final String optionId;
  final String name;

  /// `allow_once`, `allow_always`, `reject_once`, `reject_always`.
  final String kind;

  bool get allows => kind.startsWith('allow');
}

/// The agent asks before a tool call. [answered]: the chosen option (null: cancelled) once [done].
final class AgentPermissionItem extends AgentItem {
  const AgentPermissionItem({
    required this.requestId,
    required this.title,
    required this.options,
    this.done = false,
    this.answered,
  });

  final String requestId;
  final String title;
  final List<AgentPermissionOption> options;
  final bool done;
  final String? answered;

  @override
  String get key => 'q$requestId';
}

/// Something about the turn rather than from the agent: an error, a turn that stopped early
/// (`stopReason` other than `end_turn`), or the daemon's own notice (`context_lost`).
final class AgentNoticeItem extends AgentItem {
  const AgentNoticeItem(this.seq, this.kind, this.code, [this.message = '']);

  final int seq;

  /// `error`, `stopped`, `notice`.
  final String kind;
  final String code;
  final String message;

  @override
  String get key => 'n$seq';
}

List<AgentToolContent> _content(Object? v) => [
  for (final c in _l(v))
    if (_m(c) case final m)
      switch (m['type']) {
        'content' => switch (_m(m['content'])) {
          final b when b['type'] == 'text' && b['text'] is String => AgentToolText(b['text'] as String),
          _ => null,
        },
        'diff' when m['path'] is String => AgentToolDiff(
          m['path'] as String,
          _s(m['oldText']),
          '${m['newText'] ?? ''}',
        ),
        'terminal' when m['terminalId'] is String => AgentToolTerminal(m['terminalId'] as String),
        _ => null,
      },
].whereType<AgentToolContent>().toList();

List<String> _locations(Object? v) => [for (final l in _l(v)) ?_s(_m(l)['path'])];

String _blockText(Object? content) {
  final m = _m(content);
  if (m['type'] == 'text') return '${m['text'] ?? ''}';
  if (m['type'] == 'resource_link') return _s(m['name']) ?? _s(m['uri']) ?? '';
  return '';
}

/// Folds a session's events into [items]. Feed events in order; each `seq` applies once.
class AgentTranscript {
  final List<AgentItem> items = [];
  int lastSeq = 0;

  /// Index of the text item still receiving chunks (answer, thought); null after anything else.
  int? _answer;
  int? _thought;
  int? _plan;
  final _tools = <String, int>{};
  final _permissions = <String, int>{};

  bool get streaming => _answer != null || _thought != null;

  void reset() {
    items.clear();
    lastSeq = 0;
    // Text still streaming went with the items (closing it would index the emptied list).
    _answer = null;
    _thought = null;
    _plan = null;
    _tools.clear();
    _permissions.clear();
  }

  void _closeText() {
    for (final i in [_answer, _thought]) {
      if (i == null) continue;
      final t = items[i] as AgentTextItem;
      items[i] = AgentTextItem(t.seq, t.text, thought: t.thought);
    }
    _answer = null;
    _thought = null;
  }

  void _add(AgentItem item) {
    _closeText();
    items.add(item);
  }

  /// One event (`{seq, kind, …}`) from `sessions.watch` or a `session` notice.
  void apply(Map<Object?, Object?> event) {
    final seq = _i(event['seq']);
    if (seq <= lastSeq) return;
    lastSeq = seq;
    switch (event['kind']) {
      // The computer reloaded the session from the agent's own record (it went on in a terminal):
      // the history follows in full.
      case 'reset':
        reset();
        lastSeq = seq;
      case 'user':
        _plan = null;
        _add(AgentUserItem(seq, '${event['text'] ?? ''}', images: _i(event['images'])));
      case 'update':
        _update(seq, _m(event['update']));
      case 'permission':
        final call = _m(event['toolCall']);
        final id = _s(event['requestId']) ?? '$seq';
        _add(
          AgentPermissionItem(
            requestId: id,
            title: _s(call['title']) ?? _s(call['toolCallId']) ?? '',
            options: [
              for (final o in _l(event['options']))
                if (_s(_m(o)['optionId']) case final oid?)
                  AgentPermissionOption(oid, _s(_m(o)['name']) ?? oid, _s(_m(o)['kind']) ?? ''),
            ],
          ),
        );
        _permissions[id] = items.length - 1;
      case 'permission_done':
        final i = _permissions[_s(event['requestId'])];
        if (i != null) {
          final p = items[i] as AgentPermissionItem;
          items[i] = AgentPermissionItem(
            requestId: p.requestId,
            title: p.title,
            options: p.options,
            done: true,
            answered: _s(event['optionId']),
          );
        }
      case 'turn_end':
        _closeText();
        final reason = _s(event['stopReason']) ?? 'end_turn';
        if (reason != 'end_turn' && reason != 'error') items.add(AgentNoticeItem(seq, 'stopped', reason));
        for (final e in _tools.entries) {
          final t = items[e.value] as AgentToolItem;
          if (t.running && reason == 'cancelled') items[e.value] = t.merge(const {'status': 'failed'});
        }
      case 'error':
        _add(AgentNoticeItem(seq, 'error', _s(event['code']) ?? 'error', '${event['message'] ?? ''}'));
      case 'notice':
        _add(AgentNoticeItem(seq, 'notice', _s(event['code']) ?? 'notice'));
    }
  }

  void _update(int seq, Map<Object?, Object?> u) {
    switch (u['sessionUpdate']) {
      case 'agent_message_chunk' || 'agent_thought_chunk':
        final thought = u['sessionUpdate'] == 'agent_thought_chunk';
        final text = _blockText(u['content']);
        final open = thought ? _thought : _answer;
        if (open != null) {
          items[open] = (items[open] as AgentTextItem)._plus(text, streaming: true);
          return;
        }
        // A thought and an answer may interleave; anything else ends both.
        final keep = thought ? _answer : _thought;
        _closeText();
        items.add(AgentTextItem(seq, text, thought: thought, streaming: true));
        if (thought) {
          _thought = items.length - 1;
          _answer = keep;
        } else {
          _answer = items.length - 1;
          _thought = keep;
        }
      case 'user_message_chunk':
        // The daemon logs what the person sent (`user`) and drops session/load's replay; some agents
        // (Antigravity) also echo the prompt live. Showing it would repeat the message.
        return;
      case 'tool_call':
        final id = _s(u['toolCallId']) ?? '$seq';
        final existing = _tools[id];
        if (existing != null) {
          items[existing] = (items[existing] as AgentToolItem).merge(u);
          return;
        }
        _add(AgentToolItem(id: id, title: _s(u['title']) ?? id).merge(u));
        _tools[id] = items.length - 1;
      case 'tool_call_update':
        final id = _s(u['toolCallId']);
        final i = _tools[id];
        if (i == null) {
          if (id == null) return;
          _add(AgentToolItem(id: id, title: _s(u['title']) ?? id).merge(u));
          _tools[id] = items.length - 1;
          return;
        }
        items[i] = (items[i] as AgentToolItem).merge(u);
      case 'plan':
        final entries = [
          for (final e in _l(u['entries']))
            if (_s(_m(e)['content']) case final c?) AgentPlanEntry(c, _s(_m(e)['status']) ?? 'pending'),
        ];
        final at = _plan;
        if (at != null) {
          items[at] = AgentPlanItem((items[at] as AgentPlanItem).seq, entries);
        } else {
          _add(AgentPlanItem(seq, entries));
          _plan = items.length - 1;
        }
    }
  }
}
