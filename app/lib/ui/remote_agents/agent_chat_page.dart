import 'dart:async';

import 'package:dsh_link/dsh_link.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../l10n/l10n.dart';
import '../../state/remote_agents_state.dart';
import '../chat/render/diff_view.dart';
import '../chat/render/markdown_body.dart';
import '../chat/widgets/user_bubble.dart';
import '../common/brief_notice.dart';
import '../common/risk_notice.dart';
import '../phone/phone_widgets.dart';
import '../theme/app_icons.dart';
import '../theme/theme.dart';
import 'agent_env_sheet.dart';
import 'agents_page.dart' show agentStatusText;

/// One agent session on a computer: what it says and does, its questions, and a composer.
class AgentChatPage extends ConsumerStatefulWidget {
  const AgentChatPage({super.key, required this.computer, required this.session});

  final String computer;
  final String session;

  static Route<void> route({required String computer, required String session}) => MaterialPageRoute<void>(
    builder: (_) => AgentChatPage(computer: computer, session: session),
  );

  @override
  ConsumerState<AgentChatPage> createState() => _AgentChatPageState();
}

class _AgentChatPageState extends ConsumerState<AgentChatPage> {
  final _input = TextEditingController();
  final _scroll = ScrollController();

  AgentChatKey get _key => (computer: widget.computer, session: widget.session);

  @override
  void dispose() {
    _input.dispose();
    _scroll.dispose();
    super.dispose();
  }

  AgentChatController get _chat => ref.read(agentChatProvider(_key).notifier);

  Future<void> _send() async {
    final text = _input.text.trim();
    if (text.isEmpty) return;
    if (await _chat.send(text)) _input.clear();
  }

  Future<void> _toggleBypass(AgentSessionInfo info) async {
    if (!info.bypass && !await confirmRisk(context, RiskNotices.agentBypass(info.agentName))) return;
    await _chat.setBypass(!info.bypass);
  }

  void _toBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scroll.hasClients) _scroll.jumpTo(_scroll.position.maxScrollExtent);
    });
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final state = ref.watch(agentChatProvider(_key));
    final computer = ref.watch(remoteAgentsProvider.select((m) => m[widget.computer]));
    final info = state.info;
    ref.listen(agentChatProvider(_key).select((s) => s.items.length), (_, _) => _toBottom());
    ref.listen(agentChatProvider(_key).select((s) => s.error), (_, error) {
      if (error == null || !context.mounted) return;
      showBriefNotice(context, switch (error) {
        'busy' => l10n.agentsBusy,
        'closed' => l10n.agentsOffline,
        'bypass_unsupported' => l10n.agentsErrBypass,
        'bad_env' => l10n.agentsEnvBadName,
        _ => l10n.agentsSendFailed(error),
      });
    });
    final agent = info?.agentName ?? '';
    final kind = computer?.agents.where((a) => a.id == info?.agent).firstOrNull;
    final v2 = ref.read(remoteAgentsProvider.notifier).hasV2(widget.computer);
    return Scaffold(
      backgroundColor: theme.colorScheme.surface,
      appBar: AppBar(
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(info?.title ?? agent, maxLines: 1, overflow: TextOverflow.ellipsis),
            if (info != null)
              Text(
                '$agent · ${computer?.name ?? ''} · ${info.folder} · ${agentStatusText(l10n, info)}',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.bodySmall,
              ),
          ],
        ),
        actions: [
          if (info != null && info.modes.length > 1)
            PopupMenuButton<String>(
              tooltip: l10n.agentsMode,
              icon: const Icon(AppIcons.plan),
              onSelected: (m) => unawaited(_chat.setMode(m)),
              itemBuilder: (_) => [
                for (final m in info.modes)
                  CheckedPopupMenuItem(value: m.id, checked: m.id == info.mode, child: Text(m.name)),
              ],
            ),
          PopupMenuButton<String>(
            icon: const Icon(AppIcons.more),
            onSelected: (v) async {
              switch (v) {
                case 'bypass' when info != null:
                  await _toggleBypass(info);
                case 'env' when info != null:
                  await showAgentEnvSheet(context, computer: widget.computer, agent: info.agent, agentName: agent);
                case 'end':
                  if (await _chat.close() && context.mounted) Navigator.of(context).pop();
              }
            },
            itemBuilder: (_) => [
              if (v2 && info != null && kind?.bypass != null)
                CheckedPopupMenuItem(value: 'bypass', checked: info.bypass, child: Text(l10n.agentsBypass)),
              if (v2 && info != null) PopupMenuItem(value: 'env', child: Text(l10n.agentsEnv)),
              PopupMenuItem(value: 'end', child: Text(l10n.agentsEndSession)),
            ],
          ),
        ],
      ),
      body: SafeArea(
        child: Column(
          children: [
            if (!state.attached && !state.loading) PhoneNote(tone: NoteTone.warn, text: l10n.agentsOffline),
            // Said where it can't be cut off (the subtitle is): the agent no longer asks.
            if (info != null && info.bypass) PhoneNote(tone: NoteTone.warn, text: l10n.agentsBypassOnNote(agent)),
            Expanded(
              child: state.loading && state.items.isEmpty
                  ? const Center(child: CircularProgressIndicator())
                  : ListView.builder(
                      controller: _scroll,
                      padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
                      itemCount: state.items.length,
                      itemBuilder: (context, i) {
                        final item = state.items[i];
                        return Padding(
                          key: ValueKey(item.key),
                          padding: const EdgeInsets.only(bottom: 12),
                          child: _AgentItemView(item: item, agent: agent, onAnswer: _chat.answer),
                        );
                      },
                    ),
            ),
            _Composer(
              controller: _input,
              hint: l10n.agentsComposerHint(agent),
              busy: state.busy,
              enabled: state.attached,
              onSend: () => unawaited(_send()),
              onStop: () => unawaited(_chat.cancel()),
            ),
          ],
        ),
      ),
    );
  }
}

class _Composer extends StatelessWidget {
  const _Composer({
    required this.controller,
    required this.hint,
    required this.busy,
    required this.enabled,
    required this.onSend,
    required this.onStop,
  });

  final TextEditingController controller;
  final String hint;
  final bool busy;
  final bool enabled;
  final VoidCallback onSend;
  final VoidCallback onStop;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 4, 12, 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          Expanded(
            child: TextField(
              controller: controller,
              enabled: enabled,
              minLines: 1,
              maxLines: 6,
              textInputAction: TextInputAction.newline,
              decoration: InputDecoration(hintText: hint, border: const OutlineInputBorder()),
            ),
          ),
          const SizedBox(width: 8),
          if (busy)
            IconButton.filledTonal(
              tooltip: l10n.commonStop,
              icon: const Icon(AppIcons.stopGenerating),
              onPressed: onStop,
            )
          else
            IconButton.filled(tooltip: l10n.commonSend, icon: const Icon(AppIcons.send), onPressed: enabled ? onSend : null),
        ],
      ),
    );
  }
}

class _AgentItemView extends StatelessWidget {
  const _AgentItemView({required this.item, required this.agent, required this.onAnswer});

  final AgentItem item;
  final String agent;
  final Future<bool> Function(String requestId, String? optionId) onAnswer;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final colors = DshColors.of(context);
    return switch (item) {
      AgentUserItem(:final text) => Align(
        alignment: Alignment.centerRight,
        child: UserBubble(text: text),
      ),
      AgentTextItem(:final text, :final thought, :final streaming) when thought => _Thought(
        text: text,
        streaming: streaming,
      ),
      AgentTextItem(:final text, :final streaming) => MarkdownBody(text: text, streaming: streaming),
      AgentToolItem() => _Tool(item as AgentToolItem),
      AgentPlanItem(:final entries) => _Card(
        title: l10n.agentsPlan,
        icon: AppIcons.plan,
        children: [
          for (final e in entries)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 2),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(
                    e.status == 'completed' ? AppIcons.checkboxOn : AppIcons.checkboxOff,
                    size: 16,
                    color: e.status == 'in_progress' ? theme.colorScheme.primary : colors.textTertiary,
                  ),
                  const SizedBox(width: 8),
                  Expanded(child: Text(e.content, style: theme.textTheme.bodyMedium)),
                ],
              ),
            ),
        ],
      ),
      AgentPermissionItem(:final requestId, :final title, :final options, :final done, :final answered) => _Card(
        title: l10n.agentsPermissionTitle(title),
        icon: AppIcons.warning,
        accent: !done,
        children: [
          if (done)
            Text(
              answered == null
                  ? l10n.agentsPermissionCancelled
                  : l10n.agentsPermissionChosen(
                      options.where((o) => o.optionId == answered).firstOrNull?.name ?? answered,
                    ),
              style: theme.textTheme.bodySmall,
            )
          else
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final o in options)
                  o.allows
                      ? FilledButton.tonal(
                          onPressed: () => unawaited(onAnswer(requestId, o.optionId)),
                          child: Text(o.name),
                        )
                      : OutlinedButton(
                          onPressed: () => unawaited(onAnswer(requestId, o.optionId)),
                          child: Text(o.name),
                        ),
              ],
            ),
        ],
      ),
      AgentNoticeItem(:final kind, :final code, :final message) => PhoneNote(
        tone: kind == 'error' ? NoteTone.warn : NoteTone.info,
        margin: EdgeInsets.zero,
        text: switch ((kind, code)) {
          ('stopped', 'cancelled') => l10n.agentsStopped,
          ('stopped', 'max_tokens' || 'max_turn_requests') => l10n.agentsStoppedLength,
          ('stopped', 'refusal') => l10n.agentsStoppedRefusal,
          ('stopped', _) => l10n.agentsStoppedOther(code),
          ('error', 'auth_required') => l10n.agentsErrAuth(agent),
          ('error', 'agent_unavailable') => l10n.agentsErrUnavailable,
          ('error', 'agent_exited' || 'agent_gone') =>
            message.isEmpty ? l10n.agentsErrExited : '${l10n.agentsErrExited}\n$message',
          ('notice', 'context_lost') => l10n.agentsContextLost,
          ('notice', 'resumed') => l10n.agentsResumed,
          ('error', 'resume_unsupported') => l10n.agentsErrResume,
          ('error', 'mode_failed') => l10n.agentsErrMode(message),
          _ => l10n.agentsErrOther(message.isEmpty ? code : message),
        },
      ),
    };
  }
}

class _Thought extends StatelessWidget {
  const _Thought({required this.text, required this.streaming});

  final String text;
  final bool streaming;

  @override
  Widget build(BuildContext context) {
    final colors = DshColors.of(context);
    return Theme(
      data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
      child: ExpansionTile(
        tilePadding: EdgeInsets.zero,
        dense: true,
        leading: Icon(AppIcons.askAi, size: 18, color: colors.textTertiary),
        title: Text(
          context.l10n.agentsThinking,
          style: Theme.of(context).textTheme.bodySmall?.copyWith(color: colors.textTertiary),
        ),
        children: [MarkdownBody(text: text, streaming: streaming, secondary: true)],
      ),
    );
  }
}

class _Tool extends StatelessWidget {
  const _Tool(this.tool);

  final AgentToolItem tool;

  IconData get _icon => switch (tool.kind) {
    'read' || 'search' || 'fetch' => AppIcons.search,
    'edit' || 'delete' || 'move' => AppIcons.edit,
    'execute' => AppIcons.terminal,
    'think' => AppIcons.askAi,
    _ => AppIcons.tool,
  };

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = DshColors.of(context);
    final status = switch (tool.status) {
      'completed' => Icon(AppIcons.allowed, size: 16, color: colors.success),
      'failed' => Icon(AppIcons.error, size: 16, color: colors.danger),
      _ => const SizedBox.square(dimension: 14, child: CircularProgressIndicator(strokeWidth: 2)),
    };
    final hasBody = tool.content.isNotEmpty;
    final header = Row(
      children: [
        Icon(_icon, size: 18, color: colors.textTertiary),
        const SizedBox(width: 8),
        Expanded(
          child: Text(tool.title, maxLines: 2, overflow: TextOverflow.ellipsis, style: theme.textTheme.bodyMedium),
        ),
        const SizedBox(width: 8),
        status,
      ],
    );
    if (!hasBody) return header;
    return Theme(
      data: theme.copyWith(dividerColor: Colors.transparent),
      child: ExpansionTile(
        tilePadding: EdgeInsets.zero,
        dense: true,
        title: header,
        children: [
          for (final c in tool.content)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: switch (c) {
                AgentToolDiff(:final path, :final oldText, :final newText) => Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Text(path, style: theme.textTheme.bodySmall?.copyWith(fontFamily: 'JetBrainsMono')),
                    const SizedBox(height: 4),
                    DiffView(lines: computeLineDiff(oldText ?? '', newText), maxHeight: 320),
                  ],
                ),
                AgentToolText(:final text) => SelectableText(
                  text.length > 4000 ? '${text.substring(0, 4000)}…' : text,
                  style: theme.textTheme.bodySmall?.copyWith(fontFamily: 'JetBrainsMono'),
                ),
                AgentToolTerminal(:final terminalId) => Text(terminalId, style: theme.textTheme.bodySmall),
              },
            ),
        ],
      ),
    );
  }
}

class _Card extends StatelessWidget {
  const _Card({required this.title, required this.icon, required this.children, this.accent = false});

  final String title;
  final IconData icon;
  final List<Widget> children;
  final bool accent;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = DshColors.of(context);
    return DecoratedBox(
      decoration: ShapeDecoration(
        color: colors.codeWellBg,
        shape: RoundedSuperellipseBorder(
          borderRadius: AppShape.radiusMd,
          side: BorderSide(color: accent ? theme.colorScheme.primary : colors.codeWellBorder),
        ),
      ),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(icon, size: 18, color: accent ? theme.colorScheme.primary : colors.textTertiary),
                const SizedBox(width: 8),
                Expanded(child: Text(title, style: theme.textTheme.titleSmall)),
              ],
            ),
            const SizedBox(height: 8),
            ...children,
          ],
        ),
      ),
    );
  }
}
