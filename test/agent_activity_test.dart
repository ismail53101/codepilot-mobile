import 'package:flutter_test/flutter_test.dart';

import 'package:codepilot_mobile/agent_activity.dart';
import 'package:codepilot_mobile/models.dart';

AgentStep _step(
  String id,
  String tool, {
  Map<String, dynamic> args = const {},
  AgentStepStatus status = AgentStepStatus.done,
  String? detail,
}) =>
    AgentStep(id: id, title: tool, tool: tool, args: args, status: status, detail: detail);

void main() {
  group('groupActivity', () {
    test('consecutive reads collapse into one Read-files card', () {
      final blocks = groupActivity([
        StepEntry(_step('1', 'read_file', args: {'path': 'lib/a.dart'})),
        StepEntry(_step('2', 'read_file', args: {'path': 'lib/b.dart'})),
        StepEntry(_step('3', 'read_file', args: {'path': 'lib/c.dart'})),
      ]);
      expect(blocks, hasLength(1));
      expect(blocks.single.type, AgentBlockType.read);
      expect(blocks.single.items, ['lib/a.dart', 'lib/b.dart', 'lib/c.dart']);
      expect(blocks.single.countLabel, '3 files read');
    });

    test('reasoning interleaves in real order between steps', () {
      final blocks = groupActivity([
        const ReasoningEntry("I'll inspect the project first."),
        StepEntry(_step('1', 'list_files')),
        StepEntry(_step('2', 'read_file', args: {'path': 'lib/main.dart'})),
        const ReasoningEntry('Now I will update validation.'),
        StepEntry(_step('3', 'write_file',
            args: {'path': 'lib/login.dart'}, status: AgentStepStatus.done)),
      ]);
      expect(blocks.map((b) => b.type).toList(), [
        AgentBlockType.reasoning,
        AgentBlockType.inspect,
        // read merged into inspect? No — different kinds stay separate.
        AgentBlockType.read,
        AgentBlockType.reasoning,
        AgentBlockType.modify,
      ]);
    });

    test('each command becomes its own terminal card with real exit code', () {
      final blocks = groupActivity([
        StepEntry(_step('1', 'run_command',
            args: {'command': 'flutter analyze'},
            detail: 'exit=0\nNo issues found!')),
        StepEntry(_step('2', 'run_command',
            args: {'command': 'flutter test'},
            detail: 'exit=1\n2 tests failed.',
            status: AgentStepStatus.done)),
      ]);
      expect(blocks, hasLength(2));
      expect(blocks[0].type, AgentBlockType.terminal);
      expect(blocks[0].status, AgentStepStatus.done);
      expect(blocks[0].exitCode, 0);
      expect(blocks[0].output, 'No issues found!');
      expect(blocks[1].status, AgentStepStatus.failed); // exit 1 → failed
      expect(blocks[1].exitCode, 1);
      expect(blocks[1].output, '2 tests failed.');
    });
  });

  group('phasesFromSteps / remainingWork', () {
    test('only touched phases appear, with honest status', () {
      final phases = phasesFromSteps([
        _step('1', 'list_files'),
        _step('2', 'write_file', args: {'path': 'x'}),
        _step('3', 'run_command',
            args: {'command': 'ls'}, status: AgentStepStatus.running),
      ]);
      expect(phases.map((p) => p.label).toList(), [
        'Inspect project',
        'Implement changes',
        'Run commands & checks',
      ]);
      expect(phases[0].status, AgentStepStatus.done);
      expect(phases[1].status, AgentStepStatus.done);
      expect(phases[2].status, AgentStepStatus.running);
    });

    test('remainingWork lists untouched phases and interrupted ones', () {
      final remaining = remainingWork([
        _step('1', 'list_files'),
        _step('2', 'write_file',
            args: {'path': 'x'}, status: AgentStepStatus.running),
      ]);
      expect(remaining, [
        'Read relevant files',
        'Implement changes (interrupted)',
        'Run commands & checks',
        'Git operations',
      ]);
    });
  });

  group('verificationFromSteps', () {
    test('only real successful checks count', () {
      final v = verificationFromSteps([
        _step('1', 'run_command',
            args: {'command': 'flutter analyze'}, detail: 'exit=0\nok'),
        _step('2', 'run_command',
            args: {'command': 'flutter test'},
            detail: 'exit=1\nfailed',
            status: AgentStepStatus.done),
        _step('3', 'run_command',
            args: {'command': 'flutter build apk --debug'},
            detail: 'exit=0\nBuilt'),
      ]);
      expect(v.map((x) => x.label).toList(),
          ['Static analysis passed', 'Build completed']);
      expect(v.every((x) => x.passed), isTrue);
    });
  });

  group('AgentActivitySnapshot persistence', () {
    test('round-trips entries, state, timings and error', () {
      final start = DateTime(2026, 9, 20, 12);
      final snap = AgentActivitySnapshot(
        state: 'completed',
        entries: [
          const ReasoningEntry('Inspecting the auth flow.'),
          StepEntry(_step('1', 'read_file', args: {'path': 'lib/a.dart'})),
          StepEntry(_step('2', 'write_file',
              args: {'path': 'lib/a.dart'}, detail: 'OK: updated lib/a.dart')),
        ],
        startedAt: start,
        endedAt: start.add(const Duration(seconds: 42)),
        error: null,
      );
      final restored =
          AgentActivitySnapshot.fromJson(snap.toJson());
      expect(restored.state, 'completed');
      expect(restored.entries, hasLength(3));
      expect(restored.entries[0], isA<ReasoningEntry>());
      expect((restored.entries[0] as ReasoningEntry).text,
          'Inspecting the auth flow.');
      final stepEntry = restored.entries[1] as StepEntry;
      expect(stepEntry.step.tool, 'read_file');
      expect(stepEntry.step.args['path'], 'lib/a.dart');
      expect(restored.startedAt, start);
      expect(restored.endedAt, start.add(const Duration(seconds: 42)));
    });

    test('AgentStep JSON round-trip preserves status and detail', () {
      final step = _step('s1', 'run_command',
          args: {'command': 'ls'},
          status: AgentStepStatus.failed,
          detail: 'exit=126\nrejected');
      final restored = AgentStep.fromJson(step.toJson());
      expect(restored.id, 's1');
      expect(restored.tool, 'run_command');
      expect(restored.args['command'], 'ls');
      expect(restored.status, AgentStepStatus.failed);
      expect(restored.detail, 'exit=126\nrejected');
    });

    test('non-final persisted state is detected for honest restore', () {
      // Simulates a hard app kill: a snapshot saved while the task was
      // still running must be shown as cancelled, never as running.
      final snap = AgentActivitySnapshot(
        state: 'running',
        entries: [StepEntry(_step('1', 'list_files'))],
      );
      final json = snap.toJson();
      expect(json['state'], 'running'); // persisted honestly
      // The restore path in ChatScreen maps this to cancelled + reason.
    });
  });
}
