import 'package:dsh_link/dsh_link.dart';
import 'package:test/test.dart';

Map<String, Object?> upd(int seq, Map<String, Object?> u) => {'seq': seq, 'kind': 'update', 'update': u};
Map<String, Object?> chunk(int seq, String text, {bool thought = false}) => upd(seq, {
  'sessionUpdate': thought ? 'agent_thought_chunk' : 'agent_message_chunk',
  'content': {'type': 'text', 'text': text},
});

void main() {
  test('chunks stream into one answer; a thought can interleave; the turn end settles them', () {
    final t = AgentTranscript();
    t.apply({'seq': 1, 'kind': 'user', 'text': 'hi'});
    t.apply(chunk(2, 'Let me think', thought: true));
    t.apply(chunk(3, 'Hel'));
    t.apply(chunk(4, ' more', thought: true));
    t.apply(chunk(5, 'lo'));
    expect(t.streaming, isTrue);
    expect(t.items.map((i) => i.runtimeType.toString()), ['AgentUserItem', 'AgentTextItem', 'AgentTextItem']);
    final thought = t.items[1] as AgentTextItem;
    final answer = t.items[2] as AgentTextItem;
    expect((thought.thought, thought.text), (true, 'Let me think more'));
    expect((answer.text, answer.streaming), ('Hello', true));
    t.apply({'seq': 6, 'kind': 'turn_end', 'stopReason': 'end_turn'});
    expect((t.items[2] as AgentTextItem).streaming, isFalse);
    expect(t.streaming, isFalse);
    // A new answer after anything else is a new item.
    t.apply(chunk(7, 'Again'));
    expect(t.items.length, 4);
  });

  test('an agent echoing the prompt does not repeat the message', () {
    final t = AgentTranscript();
    t.apply({'seq': 1, 'kind': 'user', 'text': 'hi'});
    t.apply(
      upd(2, {
        'sessionUpdate': 'user_message_chunk',
        'content': {'type': 'text', 'text': 'hi'},
      }),
    );
    t.apply(chunk(3, 'Hello'));
    expect(t.items.map((i) => i.runtimeType.toString()), ['AgentUserItem', 'AgentTextItem']);
  });

  test('tool calls merge their updates, with diffs and text content', () {
    final t = AgentTranscript();
    t.apply(
      upd(1, {
        'sessionUpdate': 'tool_call',
        'toolCallId': 'c1',
        'title': 'Edit a.md',
        'kind': 'edit',
        'status': 'pending',
      }),
    );
    t.apply(chunk(2, 'meanwhile'));
    t.apply(
      upd(3, {
        'sessionUpdate': 'tool_call_update',
        'toolCallId': 'c1',
        'status': 'completed',
        'content': [
          {'type': 'diff', 'path': '/w/a.md', 'oldText': 'a', 'newText': 'b'},
          {
            'type': 'content',
            'content': {'type': 'text', 'text': 'ok'},
          },
        ],
        'locations': [
          {'path': '/w/a.md'},
        ],
      }),
    );
    final tool = t.items.first as AgentToolItem;
    expect((tool.title, tool.kind, tool.status, tool.running), ('Edit a.md', 'edit', 'completed', false));
    expect((tool.content[0] as AgentToolDiff).newText, 'b');
    expect((tool.content[1] as AgentToolText).text, 'ok');
    expect(tool.locations, ['/w/a.md']);
    // An update for an unseen call starts it.
    t.apply(upd(4, {'sessionUpdate': 'tool_call_update', 'toolCallId': 'c2', 'status': 'in_progress'}));
    expect((t.items.last as AgentToolItem).running, isTrue);
    // Cancelling the turn fails what was still running.
    t.apply({'seq': 5, 'kind': 'turn_end', 'stopReason': 'cancelled'});
    expect((t.items[2] as AgentToolItem).status, 'failed');
    expect((t.items.last as AgentNoticeItem).code, 'cancelled');
  });

  test('permissions, plans, errors, notices; replays apply once', () {
    final t = AgentTranscript();
    final events = <Map<String, Object?>>[
      {'seq': 1, 'kind': 'user', 'text': 'go'},
      upd(2, {
        'sessionUpdate': 'plan',
        'entries': [
          {'content': 'one', 'status': 'pending'},
        ],
      }),
      {
        'seq': 3,
        'kind': 'permission',
        'requestId': 'p1',
        'toolCall': {'title': 'Run tests'},
        'options': [
          {'optionId': 'a', 'name': 'Allow', 'kind': 'allow_once'},
          {'optionId': 'r', 'name': 'Reject', 'kind': 'reject_once'},
        ],
      },
      upd(4, {
        'sessionUpdate': 'plan',
        'entries': [
          {'content': 'one', 'status': 'completed'},
          {'content': 'two', 'status': 'in_progress'},
        ],
      }),
      {'seq': 5, 'kind': 'permission_done', 'requestId': 'p1', 'optionId': 'a'},
      {'seq': 6, 'kind': 'error', 'code': 'auth_required', 'message': 'log in'},
      {'seq': 7, 'kind': 'notice', 'code': 'context_lost'},
    ];
    for (final e in [...events, ...events]) {
      t.apply(e);
    }
    expect(t.items.length, 5);
    final plan = t.items[1] as AgentPlanItem;
    expect(plan.entries.map((e) => e.status), ['completed', 'in_progress']);
    final ask = t.items[2] as AgentPermissionItem;
    expect((ask.title, ask.done, ask.answered, ask.options.first.allows), ('Run tests', true, 'a', true));
    expect((t.items[3] as AgentNoticeItem).code, 'auth_required');
    expect((t.items[4] as AgentNoticeItem).kind, 'notice');
    expect(t.lastSeq, 7);
  });

  test('session summaries read leniently', () {
    final s = AgentSessionInfo.fromJson({
      'id': 'x',
      'agent': 'codex',
      'agentName': 'Codex',
      'cwd': '/home/me/proj',
      'status': 'running',
      'seq': 9,
      'modes': {
        'currentModeId': 'plan',
        'availableModes': [
          {'id': 'plan', 'name': 'Plan'},
          {'bad': 1},
        ],
      },
      'pending': ['p1', 3],
    })!;
    expect((s.busy, s.folder, s.mode, s.modes.single.name), (true, 'proj', 'plan', 'Plan'));
    expect(s.pending, ['p1']);
    expect(AgentSessionInfo.fromJson({'nope': 1}), isNull);
    expect(AgentKind.fromJson({'id': 'opencode', 'name': 'OpenCode', 'available': false})!.available, isFalse);
  });

  test('bypass and earlier sessions (agents.acp.v2) read leniently; older daemons mean none', () {
    expect(AgentKind.fromJson({'id': 'claude-code', 'available': true, 'bypass': 'mode'})!.bypass, AgentBypass.mode);
    expect(AgentKind.fromJson({'id': 'antigravity', 'available': true, 'bypass': 'restart'})!.bypass, AgentBypass.restart);
    expect(AgentKind.fromJson({'id': 'opencode', 'available': true, 'bypass': 'nope'})!.bypass, isNull);
    expect(AgentKind.fromJson({'id': 'old', 'available': true})!.bypass, isNull);
    final s = AgentSessionInfo.fromJson({'id': 'a', 'bypass': true, 'agentSessionId': 's-1'})!;
    expect(s.bypass, isTrue);
    expect(s.agentSessionId, 's-1');
    expect(AgentSessionInfo.fromJson({'id': 'a'})!.bypass, isFalse);

    final h = AgentHistory.fromJson({
      'listed': true,
      'canLoad': true,
      'sessions': [
        {'agentSessionId': 's-1', 'title': 'Ours', 'session': {'id': 'd1', 'status': 'running'}},
        {'agentSessionId': 't-1', 'title': 'From the terminal', 'updatedAt': '2026-01-02T00:00:00Z', 'session': null},
        {'title': 'no id, not ours'},
      ],
    });
    expect(h.listed && h.canLoad, isTrue);
    expect(h.entries.map((e) => e.agentSessionId), ['s-1', 't-1']);
    expect(h.entries.first.session!.busy, isTrue);
    expect(h.entries.last.session, isNull);
    expect(h.entries.last.updatedAt, isNotNull);
    expect(AgentHistory.fromJson(null).entries, isEmpty);
    expect(AgentHistory.fromJson({'listed': false, 'error': 'timeout'}).error, 'timeout');
  });
}
