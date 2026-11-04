import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../l10n/l10n.dart';
import '../../state/remote_agents_state.dart';
import '../engine_settings/field_row.dart';
import '../engine_settings/field_sheets.dart';
import '../theme/app_icons.dart';
import '../theme/theme.dart';

/// Edits [agent]'s environment variables on [computer] (kept in the secret store, applied when the
/// agent next starts there). Values are hidden until shown; a tapped one comes back to the fields.
Future<void> showAgentEnvSheet(
  BuildContext context, {
  required String computer,
  required String agent,
  required String agentName,
}) => showFieldSheet<void>(context, (_) => AgentEnvSheet(computer: computer, agent: agent, agentName: agentName));

class AgentEnvSheet extends ConsumerStatefulWidget {
  const AgentEnvSheet({super.key, required this.computer, required this.agent, required this.agentName});

  final String computer;
  final String agent;
  final String agentName;

  @override
  ConsumerState<AgentEnvSheet> createState() => _AgentEnvSheetState();
}

class _AgentEnvSheetState extends ConsumerState<AgentEnvSheet> {
  final _name = TextEditingController();
  final _value = TextEditingController();
  Map<String, String>? _env;
  bool _show = false;
  String? _error;

  AgentEnvStore get _store => ref.read(agentEnvStoreProvider);

  @override
  void initState() {
    super.initState();
    unawaited(_store.read(widget.computer, widget.agent).then((env) {
      if (mounted) setState(() => _env = env);
    }));
  }

  @override
  void dispose() {
    _name.dispose();
    _value.dispose();
    super.dispose();
  }

  Future<void> _save(Map<String, String> next) async {
    try {
      await _store.write(widget.computer, widget.agent, next);
      if (mounted) setState(() => _env = next);
    } on Object {
      if (mounted) setState(() => _error = context.l10n.agentsEnvSaveFailed);
    }
  }

  Future<void> _add() async {
    final env = _env;
    if (env == null) return;
    final name = _name.text.trim();
    if (!AgentEnvStore.name.hasMatch(name)) return setState(() => _error = context.l10n.agentsEnvBadName);
    setState(() => _error = null);
    final value = _value.text;
    _name.clear();
    _value.clear();
    await _save({...env, name: value});
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final env = _env;
    final muted = DshColors.of(context).textTertiary;
    return FieldSheetFrame(
      title: l10n.agentsEnvTitle(widget.agentName),
      children: [
        if (env == null)
          const Padding(padding: EdgeInsets.all(24), child: Center(child: CircularProgressIndicator()))
        else if (env.isNotEmpty)
          SheetCard(
            padding: const EdgeInsets.symmetric(vertical: 4),
            child: Material(
              type: MaterialType.transparency,
              child: Column(
                children: [
                  for (final MapEntry(:key, :value) in env.entries)
                    EngineFieldRow(
                      title: key,
                      value: _show ? value : '••••••',
                      chevron: false,
                      onTap: () => setState(() {
                        _name.text = key;
                        _value.text = value;
                      }),
                      trailing: RemoveKey(
                        tooltip: l10n.agentsEnvRemove(key),
                        onPressed: () => unawaited(_save({...env}..remove(key))),
                      ),
                    ),
                ],
              ),
            ),
          ),
        SizedBox(height: env == null || env.isEmpty ? 0 : 12),
        Row(
          children: [
            Expanded(
              child: TextField(
                key: const ValueKey('env-name'),
                controller: _name,
                autocorrect: false,
                enableSuggestions: false,
                decoration: InputDecoration(hintText: l10n.agentsEnvName),
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: TextField(
                key: const ValueKey('env-value'),
                controller: _value,
                autocorrect: false,
                enableSuggestions: false,
                obscureText: !_show,
                onSubmitted: (_) => unawaited(_add()),
                decoration: InputDecoration(
                  hintText: l10n.agentsEnvValue,
                  suffixIcon: IconButton(
                    tooltip: _show ? l10n.agentsEnvHide : l10n.agentsEnvShow,
                    icon: Icon(_show ? AppIcons.hideSecret : AppIcons.showSecret, size: 18, color: muted),
                    onPressed: () => setState(() => _show = !_show),
                  ),
                ),
              ),
            ),
            const SizedBox(width: 4),
            IconButton(
              tooltip: l10n.commonAdd,
              icon: Icon(AppIcons.addEntry, color: muted),
              onPressed: env == null ? null : () => unawaited(_add()),
            ),
          ],
        ),
        SheetHelper(helper: l10n.agentsEnvHint, error: _error),
        const SizedBox(height: 16),
      ],
    );
  }
}
