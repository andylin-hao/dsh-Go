import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../l10n/l10n.dart';
import '../../remote/link/lan_link.dart';
import '../../remote/link/link_bootstrap.dart';
import '../../remote/link/phone_link.dart';
import '../../state/hosts_state.dart';
import '../../state/phone_link_state.dart';
import '../common/app_sheet.dart';
import '../common/brief_notice.dart';
import '../common/list_page_row.dart';
import '../common/risk_notice.dart';
import '../features/feature_kit.dart';
import '../remote_agents/agents_page.dart';
import '../settings/index/spots.dart';
import '../theme/app_icons.dart';
import '../theme/theme.dart';
import 'phone_pairing.dart';
import 'phone_widgets.dart';

/// 手机操控 › 电脑: which computers' agents (Claude Code, Codex, …) may use this phone through
/// dsh-go-link (SSH hosts, and computers paired over the network), each one's link, and how to
/// register the tools with the agents there.
class PhoneComputersCard extends ConsumerWidget {
  const PhoneComputersCard({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = context.l10n;
    final hosts = ref.watch(hostsProvider.select((s) => s.ssh));
    final lan = ref.watch(lanComputersProvider);
    final grants = ref.watch(phoneLinkGrantsProvider);
    final links = ref.watch(phoneLinksProvider);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        ListPageCard(
          title: l10n.phoneLinkTitle,
          spot: Spots.phoneComputers,
          children: [
            for (final host in hosts)
              _ComputerRow(
                id: host.id,
                name: host.name,
                icon: AppIcons.sshHost,
                on: grants.contains(host.id),
                status: links[host.id],
                onOpen: () => showPhoneLinkSheet(context, id: host.id, name: host.name),
              ),
            for (final c in lan)
              _ComputerRow(
                id: c.id,
                name: c.name,
                icon: AppIcons.computer,
                on: grants.contains(c.id),
                status: links[c.id],
                onOpen: () => showPhoneLinkSheet(context, id: c.id, name: c.name, lan: c),
              ),
            if (hosts.isEmpty && lan.isEmpty)
              ListPageRow(
                icon: AppIcons.computer,
                iconColor: DshColors.of(context).textTertiary,
                title: l10n.phoneLinkNoHosts,
                subtitle: l10n.phoneLinkNoHostsHint,
                subtitleMaxLines: 2,
              ),
            ListPageRow(
              icon: AppIcons.link,
              title: l10n.phoneLinkPair,
              subtitle: l10n.phoneLinkPairHint,
              subtitleMaxLines: 2,
              onTap: () => unawaited(showPairSheet(context)),
            ),
          ],
        ),
        PageFootnote(l10n.phoneLinkHint),
      ],
    );
  }
}

class _ComputerRow extends ConsumerWidget {
  const _ComputerRow({
    required this.id,
    required this.name,
    required this.icon,
    required this.on,
    required this.status,
    required this.onOpen,
  });

  final String id;
  final String name;
  final IconData icon;
  final bool on;
  final PhoneLinkStatus? status;
  final Future<void> Function() onOpen;

  Future<void> _toggle(BuildContext context, WidgetRef ref, bool next) async {
    if (next && !await confirmRisk(context, RiskNotices.phoneComputer(name))) return;
    await ref.read(phoneLinkGrantsProvider.notifier).set(id, next);
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = context.l10n;
    final s = status;
    final problem = s != null && (s.phase == PhoneLinkPhase.failed || s.phase == PhoneLinkPhase.waiting);
    return MergeSemantics(
      child: ListPageRow(
        icon: icon,
        iconColor: s?.phase == PhoneLinkPhase.failed ? DshColors.of(context).warning : null,
        title: name,
        subtitle: on ? phoneLinkStatusLine(l10n, s) : l10n.phoneLinkOff,
        subtitleColor: problem ? DshColors.of(context).warning : null,
        subtitleMaxLines: 2,
        onTap: on ? () => unawaited(onOpen()) : () => unawaited(_toggle(context, ref, true)),
        trailing: Switch(value: on, onChanged: (v) => unawaited(_toggle(context, ref, v))),
      ),
    );
  }
}

/// The row's one line for [status] (null: not started yet).
String phoneLinkStatusLine(L10n l10n, PhoneLinkStatus? status) {
  final s = status;
  if (s == null) return l10n.phoneLinkConnecting;
  return switch (s.phase) {
    PhoneLinkPhase.connecting => l10n.phoneLinkConnecting,
    PhoneLinkPhase.attached =>
      s.agents.isEmpty ? l10n.phoneLinkAttached : l10n.phoneLinkAttachedAgents(s.agents.toSet().join(', ')),
    PhoneLinkPhase.waiting => l10n.phoneLinkWaiting(phoneLinkErrorText(l10n, s.error)),
    PhoneLinkPhase.failed => phoneLinkErrorText(l10n, s.error),
  };
}

String phoneLinkErrorText(L10n l10n, PhoneLinkError? e) => switch (e?.kind) {
  null || PhoneLinkErrorKind.lost => l10n.phoneLinkErrLost,
  PhoneLinkErrorKind.ssh => e!.message ?? l10n.phoneLinkErrSsh,
  PhoneLinkErrorKind.hostKeyUnknown => l10n.phoneLinkErrHostKeyUnknown,
  PhoneLinkErrorKind.hostKeyChanged => l10n.phoneLinkErrHostKeyChanged,
  PhoneLinkErrorKind.noShell => l10n.phoneLinkErrNoShell,
  PhoneLinkErrorKind.nodeMissing => l10n.phoneLinkErrNodeMissing,
  PhoneLinkErrorKind.nodeOld => l10n.phoneLinkErrNodeOld(e!.detail ?? '?'),
  PhoneLinkErrorKind.install => l10n.phoneLinkErrInstall,
  PhoneLinkErrorKind.start => l10n.phoneLinkErrStart,
  PhoneLinkErrorKind.refused => l10n.phoneLinkErrRefused,
  PhoneLinkErrorKind.replaced => l10n.phoneLinkErrReplaced,
  PhoneLinkErrorKind.unreachable => l10n.phoneLinkErrUnreachable,
  PhoneLinkErrorKind.notPaired => l10n.phoneLinkErrNotPaired,
};

/// One computer: its link (with 重试 when it needs it), its agent sessions, and the per-agent
/// registration snippets.
Future<void> showPhoneLinkSheet(BuildContext context, {required String id, required String name, LanComputer? lan}) =>
    showAppSheet<void>(
      context,
      heightFactor: 0.86,
      isScrollControlled: true,
      builder: (_) => PhoneLinkSheet(id: id, name: name, lan: lan),
    );

class PhoneLinkSheet extends ConsumerStatefulWidget {
  const PhoneLinkSheet({super.key, required this.id, required this.name, this.lan});

  final String id;
  final String name;
  final LanComputer? lan;

  @override
  ConsumerState<PhoneLinkSheet> createState() => _PhoneLinkSheetState();
}

class _PhoneLinkSheetState extends ConsumerState<PhoneLinkSheet> {
  Future<List<AgentSetup>>? _setup;

  @override
  void initState() {
    super.initState();
    _load();
  }

  void _load() {
    final link = ref.read(phoneLinksProvider.notifier).link(widget.id);
    setState(() => _setup = link?.agentSetup() ?? Future.error(const PhoneLinkError(PhoneLinkErrorKind.lost)));
  }

  Future<void> _forget() async {
    await ref.read(lanComputersProvider.notifier).forget(widget.id);
    if (mounted) Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final status = ref.watch(phoneLinksProvider.select((m) => m[widget.id]));
    final failed = status?.phase == PhoneLinkPhase.failed || status?.phase == PhoneLinkPhase.waiting;
    final cockpit = status != null && status.attached && status.caps.contains('agents.acp.v1');
    return SafeArea(
      top: false,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SheetHeader(l10n.phoneLinkSetupTitle(widget.name), maxLines: 2),
          Expanded(
            child: ListView(
              padding: const EdgeInsets.only(bottom: 24),
              children: [
                PhoneNote(
                  tone: failed ? NoteTone.warn : NoteTone.info,
                  text: phoneLinkStatusLine(l10n, status),
                  action: failed
                      ? FixButton(
                          label: l10n.commonRetry,
                          onPressed: () {
                            ref.read(phoneLinksProvider.notifier).retry(widget.id);
                            _load();
                          },
                        )
                      : null,
                  margin: const EdgeInsets.fromLTRB(kSheetGutter, 4, kSheetGutter, 12),
                ),
                if (cockpit)
                  ListPageCard(
                    margin: const EdgeInsets.fromLTRB(kSheetGutter, 0, kSheetGutter, 12),
                    children: [
                      ListPageRow(
                        icon: AppIcons.bot,
                        title: l10n.phoneLinkAgents,
                        subtitle: l10n.phoneLinkAgentsHint,
                        subtitleMaxLines: 2,
                        onTap: () => Navigator.of(context).push(RemoteAgentsPage.route()),
                      ),
                    ],
                  ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(kSheetGutter, 0, kSheetGutter, 12),
                  child: Text(l10n.phoneLinkSetupBody, style: Theme.of(context).textTheme.bodyMedium),
                ),
                FutureBuilder<List<AgentSetup>>(
                  future: _setup,
                  builder: (context, snap) {
                    if (snap.connectionState != ConnectionState.done) {
                      return QuietSpinner(
                        label: l10n.phoneLinkSetupLoading,
                        padding: const EdgeInsets.symmetric(vertical: 32),
                      );
                    }
                    final agents = snap.data;
                    if (agents == null) {
                      final e = snap.error;
                      final reason = e is PhoneLinkError ? phoneLinkErrorText(l10n, e) : '$e';
                      return PhoneNote(
                        tone: NoteTone.warn,
                        text: l10n.phoneLinkSetupFailed(reason),
                        action: FixButton(label: l10n.commonRetry, onPressed: _load),
                        margin: const EdgeInsets.symmetric(horizontal: kSheetGutter),
                      );
                    }
                    return Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [for (final a in agents) _Snippet(a)],
                    );
                  },
                ),
                PageFootnote(l10n.phoneLinkSetupNote),
                if (widget.lan case final lan?) ...[
                  PageFootnote(l10n.phoneLinkKey(lan.fingerprint)),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(kSheetGutter, 16, kSheetGutter, 0),
                    child: OutlinedButton(onPressed: _forget, child: Text(l10n.phoneLinkForget)),
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _Snippet extends StatelessWidget {
  const _Snippet(this.setup);

  final AgentSetup setup;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final colors = DshColors.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(kSheetGutter, 8, kSheetGutter, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(setup.name, style: theme.textTheme.titleSmall),
                    Text(
                      setup.command ? l10n.phoneLinkSetupRun : l10n.phoneLinkSetupAddTo(setup.file ?? ''),
                      style: theme.textTheme.bodySmall?.copyWith(color: colors.textTertiary),
                    ),
                  ],
                ),
              ),
              CopyButton(setup.text),
            ],
          ),
          const SizedBox(height: 6),
          CodeWell(setup.text.trimRight()),
        ],
      ),
    );
  }
}

/// Copies [text], with the 已复制 toast.
class CopyButton extends StatelessWidget {
  const CopyButton(this.text, {super.key});

  final String text;

  @override
  Widget build(BuildContext context) => IconButton(
    tooltip: context.l10n.commonCopy,
    icon: const Icon(AppIcons.copy),
    onPressed: () async {
      await Clipboard.setData(ClipboardData(text: text));
      if (context.mounted) showBriefNotice(context, context.l10n.commonCopied);
    },
  );
}

/// Monospace text in the code well, scrolling sideways, selectable.
class CodeWell extends StatelessWidget {
  const CodeWell(this.text, {super.key});

  final String text;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = DshColors.of(context);
    return DecoratedBox(
      decoration: ShapeDecoration(
        color: colors.codeWellBg,
        shape: RoundedSuperellipseBorder(
          borderRadius: AppShape.radiusMd,
          side: BorderSide(color: colors.codeWellBorder),
        ),
      ),
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.all(12),
        child: SelectableText(
          text,
          style: theme.textTheme.bodySmall?.copyWith(fontFamily: 'JetBrainsMono', height: 1.5),
        ),
      ),
    );
  }
}
