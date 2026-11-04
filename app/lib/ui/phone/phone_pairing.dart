import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../l10n/l10n.dart';
import '../../links/app_links.dart';
import '../../remote/link/lan_link.dart';
import '../../state/phone_link_state.dart';
import '../../state/phone_state.dart';
import '../common/app_sheet.dart';
import '../common/brief_notice.dart';
import '../common/risk_notice.dart';
import 'phone_computers.dart' show CodeWell, CopyButton;

/// Where a computer without SSH gets dsh-go-link (the same file the app installs over SSH).
const linkScriptUrl = 'https://raw.githubusercontent.com/ccch1mneyyy/dsh-go/main/host/dsh-go-link/bin/dsh-go-link.cjs';
const linkDownloadCommand = 'curl -fsSL $linkScriptUrl -o dsh-go-link.cjs';
const linkPairCommand = 'node dsh-go-link.cjs pair';

/// `dshgo://link?…` (the pairing QR, opened by the camera or pasted): asks, then pairs.
final phonePairingRouteProvider = Provider<void>((ref) {
  final router = ref.watch(linkRouterProvider);
  final off = router.registerLinkHandler('link', (uri) async {
    final context = router.context;
    final pairing = LinkPairing.parse(uri);
    if (context == null || pairing == null) return false;
    await pairWith(context, pairing);
    return true;
  });
  ref.onDispose(off);
});

/// Confirms [pairing] (its name and key fingerprint), then saves and links the computer.
Future<bool> pairWith(BuildContext context, LinkPairing pairing) async {
  final container = ProviderScope.containerOf(context, listen: false);
  final l10n = context.l10n;
  final computer = LanComputer.of(pairing);
  if (!await confirmRisk(context, RiskNotices.phonePair(pairing.name, computer.fingerprint))) return false;
  await container.read(lanComputersProvider.notifier).pair(pairing);
  if (!context.mounted) return true;
  final on = container.read(phoneProvider).status.enabled;
  showBriefNotice(context, on ? l10n.phoneLinkPaired(pairing.name) : l10n.phoneLinkPairNeedsPhoneControl);
  return true;
}

/// 配对局域网里的电脑: what to run on the computer, and a field for the link it prints.
Future<void> showPairSheet(BuildContext context) => showAppSheet<void>(
  context,
  heightFactor: 0.86,
  isScrollControlled: true,
  builder: (_) => const PairSheet(),
);

class PairSheet extends StatefulWidget {
  const PairSheet({super.key});

  @override
  State<PairSheet> createState() => _PairSheetState();
}

class _PairSheetState extends State<PairSheet> {
  final _field = TextEditingController();
  String? _error;

  @override
  void dispose() {
    _field.dispose();
    super.dispose();
  }

  Future<void> _paste() async {
    final text = (await Clipboard.getData(Clipboard.kTextPlain))?.text?.trim() ?? '';
    if (text.isNotEmpty) _field.text = text;
    await _submit();
  }

  Future<void> _submit() async {
    final uri = Uri.tryParse(_field.text.trim());
    final pairing = uri == null ? null : LinkPairing.parse(uri);
    if (pairing == null) {
      setState(() => _error = context.l10n.phoneLinkPairInvalid);
      return;
    }
    setState(() => _error = null);
    final navigator = Navigator.of(context);
    if (await pairWith(context, pairing) && mounted) navigator.pop();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    Widget step(String text) => Padding(
      padding: const EdgeInsets.fromLTRB(kSheetGutter, 16, kSheetGutter, 8),
      child: Text(text, style: theme.textTheme.bodyMedium),
    );
    Widget command(String text) => Padding(
      padding: const EdgeInsets.symmetric(horizontal: kSheetGutter),
      child: Row(
        children: [
          Expanded(child: CodeWell(text)),
          CopyButton(text),
        ],
      ),
    );
    return SafeArea(
      top: false,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SheetHeader(l10n.phoneLinkPairTitle),
          Expanded(
            child: ListView(
              padding: EdgeInsets.only(bottom: 24 + MediaQuery.viewInsetsOf(context).bottom),
              children: [
                step(l10n.phoneLinkPairStep1),
                command(linkDownloadCommand),
                step(l10n.phoneLinkPairStep2),
                command(linkPairCommand),
                step(l10n.phoneLinkPairStep3),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: kSheetGutter),
                  child: TextField(
                    controller: _field,
                    minLines: 1,
                    maxLines: 3,
                    keyboardType: TextInputType.url,
                    decoration: InputDecoration(hintText: 'dshgo://link?…', errorText: _error),
                    onSubmitted: (_) => unawaited(_submit()),
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(kSheetGutter, 12, kSheetGutter, 0),
                  child: Row(
                    children: [
                      Expanded(
                        child: OutlinedButton(onPressed: () => unawaited(_paste()), child: Text(l10n.phoneLinkPairPaste)),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: FilledButton(onPressed: () => unawaited(_submit()), child: Text(l10n.phoneLinkPairAction)),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 8),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: kSheetGutter, vertical: 8),
                  child: Text(l10n.phoneLinkPairHint, style: theme.textTheme.bodySmall),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
