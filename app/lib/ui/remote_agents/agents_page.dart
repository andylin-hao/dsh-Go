import 'dart:async';

import 'package:dsh_link/dsh_link.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../l10n/l10n.dart';
import '../../state/remote_agents_state.dart';
import '../common/app_sheet.dart';
import '../common/list_page_row.dart';
import '../common/risk_notice.dart';
import '../common/status_dot.dart';
import '../features/feature_kit.dart';
import '../forum/forum_widgets.dart' show forumAgo;
import '../phone/phone_widgets.dart';
import '../shell/page_frame.dart';
import '../theme/app_icons.dart';
import '../theme/theme.dart';
import 'agent_chat_page.dart';
import 'agent_env_sheet.dart';

/// 电脑上的智能体: the agent sessions on every attached computer that runs agents, and new ones.
class RemoteAgentsPage extends ConsumerWidget {
  const RemoteAgentsPage({super.key});

  static Route<void> route() => MaterialPageRoute<void>(builder: (_) => const RemoteAgentsPage());

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = context.l10n;
    final computers = ref.watch(remoteAgentsProvider).values.toList();
    return AppPage.list(
      title: l10n.agentsTitle,
      subtitle: Text(l10n.agentsSubtitle),
      children: [
        if (computers.isEmpty)
          PhoneNote(
            text: '${l10n.agentsEmpty}. ${l10n.agentsEmptyHint}',
            margin: const EdgeInsets.symmetric(horizontal: 16),
          ),
        for (final c in computers) ...[
          ListPageCard(
            title: c.name,
            children: [
              if (c.loading && c.sessions.isEmpty)
                const QuietSpinner(padding: EdgeInsets.symmetric(vertical: 24))
              else if (c.sessions.isEmpty)
                ListPageRow(
                  icon: AppIcons.bot,
                  iconColor: DshColors.of(context).textTertiary,
                  title: c.available.isEmpty ? l10n.agentsNoneInstalled : l10n.agentsNoSessions,
                  titleMaxLines: 3,
                ),
              for (final s in c.sessions)
                ListPageRow(
                  icon: AppIcons.bot,
                  title: s.title ?? s.agentName,
                  subtitle: [
                    s.agentName,
                    if (s.bypass) l10n.agentsBypassTag,
                    s.folder,
                    agentStatusText(l10n, s),
                  ].join(' · '),
                  trailing: s.pending.isNotEmpty
                      ? const StatusDot(tone: StatusTone.warn, size: 8)
                      : s.busy
                      ? const StatusDot(tone: StatusTone.busy, size: 8)
                      : null,
                  onTap: () => Navigator.of(context).push(AgentChatPage.route(computer: c.id, session: s.id)),
                ),
              if (c.available.isNotEmpty)
                ListPageRow(
                  icon: AppIcons.add,
                  title: l10n.agentsNew,
                  onTap: () => unawaited(startAgentSession(context, c)),
                ),
            ],
          ),
          const SizedBox(height: 24),
        ],
      ],
    );
  }
}

/// Picks an agent and a folder on [computer] (or one of the folder's earlier sessions), then
/// opens that session's chat. False when the sheet was closed without one.
Future<bool> startAgentSession(BuildContext context, AgentComputer computer) async {
  final id = await showAppSheet<String>(
    context,
    heightFactor: 0.86,
    isScrollControlled: true,
    builder: (_) => NewAgentSessionSheet(computer: computer),
  );
  if (id == null || !context.mounted) return false;
  unawaited(Navigator.of(context).push(AgentChatPage.route(computer: computer.id, session: id)));
  return true;
}

String agentStatusText(L10n l10n, AgentSessionInfo s) {
  if (s.pending.isNotEmpty) return l10n.agentsWaitingForYou;
  return switch (s.status) {
    'running' => l10n.agentsStatusRunning,
    'starting' => l10n.agentsStatusStarting,
    'idle' => l10n.agentsStatusIdle,
    _ => l10n.agentsStatusStopped,
  };
}

/// Picks the agent and the folder on the computer, then starts a session there or continues one of
/// the folder's earlier sessions (pops with the session's id). With `agents.acp.v2` it also sets the
/// agent's environment and whether it skips permission prompts.
class NewAgentSessionSheet extends ConsumerStatefulWidget {
  const NewAgentSessionSheet({super.key, required this.computer});

  final AgentComputer computer;

  @override
  ConsumerState<NewAgentSessionSheet> createState() => _NewAgentSessionSheetState();
}

class _NewAgentSessionSheetState extends ConsumerState<NewAgentSessionSheet> {
  late String _agent = widget.computer.available.first.id;
  ({String path, String? parent, List<String> dirs})? _folder;
  String? _error;
  bool _starting = false;
  bool _bypass = false;
  int _envCount = 0;
  AgentHistory? _history;
  String? _historyFor;
  Timer? _historyTimer;

  RemoteAgentsController get _agents => ref.read(remoteAgentsProvider.notifier);
  bool get _v2 => _agents.hasV2(widget.computer.id);

  @override
  void initState() {
    super.initState();
    unawaited(_open(null));
    // Agents installed (or configured) since the computer attached show up too.
    unawaited(_agents.refresh(widget.computer.id));
    unawaited(_countEnv());
  }

  @override
  void dispose() {
    _historyTimer?.cancel();
    super.dispose();
  }

  Future<void> _open(String? path) async {
    try {
      final f = await _agents.folders(widget.computer.id, path);
      if (!mounted) return;
      setState(() {
        _folder = f;
        _error = null;
      });
      _loadHistory();
    } on LinkCallError catch (e) {
      // A recent folder that is gone from the computer leaves the list.
      if (e.code == 'no_folder' && path != null) {
        unawaited(ref.read(agentRecentFoldersProvider.notifier).remove(widget.computer.id, path));
      }
      if (mounted) setState(() => _error = e.message.isEmpty ? e.code : e.message);
    }
  }

  /// This phone's recent folders on the computer, then the folders of its sessions, newest first.
  List<String> _recents(List<String> stored, List<AgentSessionInfo> sessions) => {
    ...stored,
    for (final s in sessions)
      if (s.cwd.isNotEmpty) s.cwd,
  }.take(AgentRecentFolders.max).toList();

  static String _lastPart(String path) => path.split(RegExp(r'[/\\]')).where((p) => p.isNotEmpty).lastOrNull ?? path;

  void _pickAgent(String id) {
    if (id == _agent) return;
    setState(() {
      _agent = id;
      _bypass = false;
    });
    unawaited(_countEnv());
    _loadHistory();
  }

  Future<void> _countEnv() async {
    final agent = _agent;
    final env = await ref.read(agentEnvStoreProvider).read(widget.computer.id, agent);
    if (mounted && agent == _agent) setState(() => _envCount = env.length);
  }

  /// The folder's earlier sessions of the chosen agent, once the folder has settled (each ask
  /// starts the agent briefly on the computer).
  void _loadHistory() {
    final folder = _folder;
    if (folder == null || !_v2) return;
    final key = '$_agent\u0000${folder.path}';
    if (key == _historyFor) return;
    _historyTimer?.cancel();
    setState(() {
      _historyFor = key;
      _history = null;
    });
    _historyTimer = Timer(const Duration(milliseconds: 500), () async {
      AgentHistory h;
      try {
        h = await _agents.history(widget.computer.id, _agent, folder.path);
      } on LinkCallError catch (e) {
        h = AgentHistory(error: e.code);
      }
      if (mounted && key == _historyFor) setState(() => _history = h);
    });
  }

  AgentKind? get _kind =>
      ref.read(remoteAgentsProvider)[widget.computer.id]?.agents.where((a) => a.id == _agent).firstOrNull;

  Future<void> _toggleBypass(bool on, String agentName) async {
    if (on && !await confirmRisk(context, RiskNotices.agentBypass(agentName))) return;
    if (mounted) setState(() => _bypass = on);
  }

  Future<void> _go(Future<String> Function() open) async {
    setState(() => _starting = true);
    try {
      final id = await open();
      if (mounted) Navigator.of(context).pop(id);
    } on LinkCallError catch (e) {
      if (mounted) {
        setState(() {
          _error = e.message.isEmpty ? e.code : e.message;
          _starting = false;
        });
      }
    }
  }

  Future<void> _start() async {
    final folder = _folder;
    if (folder == null) return;
    await _go(() => _agents.start(widget.computer.id, _agent, folder.path, bypass: _bypass));
  }

  Future<void> _resume(AgentHistoryEntry entry) async {
    final folder = _folder;
    if (folder == null) return;
    await _go(() => _agents.resume(widget.computer.id, _agent, folder.path, entry, bypass: _bypass));
  }

  String _join(String base, String name) => base.endsWith('/') || base.endsWith('\\') ? '$base$name' : '$base/$name';

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final folder = _folder;
    final agents =
        ref.watch(remoteAgentsProvider.select((m) => m[widget.computer.id]?.available)) ?? widget.computer.available;
    final kind = agents.where((a) => a.id == _agent).firstOrNull ?? _kind;
    final agentName = kind?.name ?? _agent;
    final v2 = _v2;
    final stored = ref.watch(agentRecentFoldersProvider.select((m) => m[widget.computer.id])) ?? const <String>[];
    final recents = _recents(
      stored,
      ref.watch(remoteAgentsProvider.select((m) => m[widget.computer.id]?.sessions)) ?? widget.computer.sessions,
    );
    return SafeArea(
      top: false,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SheetHeader(l10n.agentsNewTitle(widget.computer.name), maxLines: 2),
          Expanded(
            child: ListView(
              padding: const EdgeInsets.only(bottom: 16),
              children: [
                ListPageCard(
                  title: l10n.agentsPickAgent,
                  margin: const EdgeInsets.symmetric(horizontal: kSheetGutter),
                  children: [
                    for (final a in agents)
                      ListPageRow(
                        icon: AppIcons.bot,
                        title: a.name,
                        trailing: _agent == a.id ? const Icon(AppIcons.allowed) : null,
                        onTap: () => _pickAgent(a.id),
                      ),
                  ],
                ),
                if (v2) ...[
                  const SizedBox(height: 20),
                  ListPageCard(
                    margin: const EdgeInsets.symmetric(horizontal: kSheetGutter),
                    children: [
                      ListPageRow(
                        icon: AppIcons.terminal,
                        title: l10n.agentsEnv,
                        value: _envCount == 0 ? l10n.agentsEnvNone : l10n.agentsEnvCount(_envCount),
                        chevron: true,
                        onTap: () async {
                          await showAgentEnvSheet(
                            context,
                            computer: widget.computer.id,
                            agent: _agent,
                            agentName: agentName,
                          );
                          unawaited(_countEnv());
                        },
                      ),
                      if (kind?.bypass case final bypass?)
                        ListPageRow(
                          icon: AppIcons.approval,
                          title: l10n.agentsBypass,
                          subtitle: bypass == AgentBypass.mode
                              ? l10n.agentsBypassHintMode
                              : l10n.agentsBypassHintRestart,
                          subtitleMaxLines: 2,
                          trailing: Switch(value: _bypass, onChanged: (v) => unawaited(_toggleBypass(v, agentName))),
                        ),
                    ],
                  ),
                ],
                if (recents.isNotEmpty) ...[
                  const SizedBox(height: 20),
                  ListPageCard(
                    title: l10n.agentsRecentFolders,
                    margin: const EdgeInsets.symmetric(horizontal: kSheetGutter),
                    children: [
                      for (final p in recents)
                        ListPageRow(
                          icon: AppIcons.history,
                          title: _lastPart(p),
                          subtitle: p,
                          trailing: folder?.path == p
                              ? const Icon(AppIcons.allowed)
                              : stored.contains(p)
                              ? IconButton(
                                  tooltip: l10n.agentsRecentRemove(_lastPart(p)),
                                  visualDensity: VisualDensity.compact,
                                  icon: const Icon(AppIcons.close, size: 18),
                                  onPressed: () => unawaited(
                                    ref.read(agentRecentFoldersProvider.notifier).remove(widget.computer.id, p),
                                  ),
                                )
                              : null,
                          onTap: folder?.path == p ? null : () => unawaited(_open(p)),
                        ),
                    ],
                  ),
                ],
                const SizedBox(height: 20),
                ListPageCard(
                  title: l10n.agentsPickFolder,
                  margin: const EdgeInsets.symmetric(horizontal: kSheetGutter),
                  children: [
                    if (folder == null)
                      const QuietSpinner(padding: EdgeInsets.symmetric(vertical: 24))
                    else ...[
                      ListPageRow(icon: AppIcons.folder, title: folder.path, titleMaxLines: 3),
                      if (folder.parent case final parent?)
                        ListPageRow(icon: AppIcons.back, title: l10n.agentsUp, onTap: () => unawaited(_open(parent))),
                    ],
                  ],
                ),
                if (v2 && folder != null) ...[
                  const SizedBox(height: 20),
                  _EarlierSessions(
                    history: _history,
                    agentName: agentName,
                    enabled: !_starting,
                    onOpen: (e) => unawaited(_resume(e)),
                  ),
                ],
                if (folder != null && folder.dirs.isNotEmpty) ...[
                  const SizedBox(height: 20),
                  ListPageCard(
                    title: l10n.agentsSubfolders,
                    margin: const EdgeInsets.symmetric(horizontal: kSheetGutter),
                    children: [
                      for (final d in folder.dirs.take(200))
                        ListPageRow(
                          icon: AppIcons.folder,
                          title: d,
                          chevron: true,
                          onTap: () => unawaited(_open(_join(folder.path, d))),
                        ),
                    ],
                  ),
                ],
                if (_error case final e?) PhoneNote(tone: NoteTone.warn, text: e),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(kSheetGutter, 8, kSheetGutter, 12),
            child: FilledButton(
              onPressed: folder == null || _starting ? null : () => unawaited(_start()),
              child: Text(l10n.agentsStartHere),
            ),
          ),
        ],
      ),
    );
  }
}

/// The folder's earlier sessions of one agent: the computer's own (open as they are) and the
/// agent's (resumed with their history).
class _EarlierSessions extends StatelessWidget {
  const _EarlierSessions({required this.history, required this.agentName, required this.enabled, required this.onOpen});

  final AgentHistory? history;
  final String agentName;
  final bool enabled;
  final ValueChanged<AgentHistoryEntry> onOpen;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final muted = DshColors.of(context).textTertiary;
    final h = history;
    String? note;
    if (h != null && h.entries.isEmpty) {
      note = h.error != null
          ? l10n.agentsEarlierFailed(agentName, h.error!)
          : h.listed
          ? l10n.agentsEarlierEmpty(agentName)
          : l10n.agentsEarlierUnlisted(agentName);
    } else if (h != null && h.listed && !h.canLoad) {
      note = l10n.agentsEarlierNoLoad(agentName);
    }
    return ListPageCard(
      title: l10n.agentsEarlier,
      margin: const EdgeInsets.symmetric(horizontal: kSheetGutter),
      children: [
        if (h == null) const QuietSpinner(padding: EdgeInsets.symmetric(vertical: 24)),
        for (final e in h?.entries ?? const <AgentHistoryEntry>[])
          if (e.session case final s?)
            ListPageRow(
              icon: AppIcons.bot,
              title: s.title ?? e.title ?? agentName,
              subtitle: '${agentStatusText(l10n, s)} · ${forumAgo(s.updatedAt ?? e.updatedAt)}',
              trailing: s.pending.isNotEmpty
                  ? const StatusDot(tone: StatusTone.warn, size: 8)
                  : s.busy
                  ? const StatusDot(tone: StatusTone.busy, size: 8)
                  : null,
              onTap: enabled ? () => onOpen(e) : null,
            )
          else
            ListPageRow(
              icon: AppIcons.history,
              iconColor: h!.canLoad ? null : muted,
              title: e.title ?? agentName,
              subtitle: l10n.agentsEarlierOnComputer(forumAgo(e.updatedAt)),
              onTap: enabled && h.canLoad ? () => onOpen(e) : null,
            ),
        if (note != null) ListPageRow(icon: AppIcons.history, iconColor: muted, title: note, titleMaxLines: 3),
      ],
    );
  }
}
