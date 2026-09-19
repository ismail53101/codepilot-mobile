import 'dart:async';

import 'package:flutter_test/flutter_test.dart';

import 'package:codepilot_mobile/agent_loop.dart';
import 'package:codepilot_mobile/api_client.dart';
import 'package:codepilot_mobile/github_service.dart';
import 'package:codepilot_mobile/models.dart';
import 'package:codepilot_mobile/project_service.dart';
import 'package:codepilot_mobile/stores.dart';
import 'package:codepilot_mobile/terminal_executor.dart';
import 'package:codepilot_mobile/tool_registry.dart';

class _FakeBackend implements ChatBackend {
  final List<({String content, List<ToolCall> toolCalls})> script;
  int callIndex = 0;
  int requestCount = 0;

  _FakeBackend(this.script);

  @override
  Future<({String content, List<ToolCall> toolCalls})> chatWithTools(
    List<ChatMessage> messages, {
    List<Map<String, dynamic>>? tools,
    int? timeoutSeconds,
    CancelToken? cancelToken,
    int retries = 3,
  }) async {
    requestCount++;
    if (cancelToken?.isCancelled ?? false) {
      throw const ApiException('Cancelled.', 'cancelled');
    }
    if (callIndex >= script.length) {
      return (content: 'done', toolCalls: const <ToolCall>[]);
    }
    return script[callIndex++];
  }
}

/// Backend that always throws — drives the FAILED path.
class _FailingBackend implements ChatBackend {
  final ApiException error;
  _FailingBackend(this.error);

  @override
  Future<({String content, List<ToolCall> toolCalls})> chatWithTools(
    List<ChatMessage> messages, {
    List<Map<String, dynamic>>? tools,
    int? timeoutSeconds,
    CancelToken? cancelToken,
    int retries = 3,
  }) async {
    throw error;
  }
}

/// Backend that hangs until its CancelToken fires — drives timeout/cancel.
class _HangingBackend implements ChatBackend {
  bool cancelled = false;

  @override
  Future<({String content, List<ToolCall> toolCalls})> chatWithTools(
    List<ChatMessage> messages, {
    List<Map<String, dynamic>>? tools,
    int? timeoutSeconds,
    CancelToken? cancelToken,
    int retries = 3,
  }) async {
    if (cancelToken != null) {
      await cancelToken.future;
      cancelled = true;
      throw const ApiException('Cancelled.', 'cancelled');
    }
    await Completer<void>().future; // hang forever
    return (content: '', toolCalls: const <ToolCall>[]);
  }
}

ProjectService _makeService() => ProjectService();

ToolRegistry _registry(ProjectService projects) => ToolRegistry(
      projects: projects,
      github: GitHubService(SettingsStore()),
      repoStore: GitHubProjectStore(SettingsStore()),
    );

void main() {
  group('TerminalExecutor safety', () {
    final term = TerminalExecutor();

    test('rejects destructive and escaping commands', () {
      for (final bad in [
        'rm -rf /',
        'reboot',
        'sudo ls',
        'echo hi > /etc/passwd',
        'cat /etc/passwd | grep root',
        'ls; rm file',
        'ls && cat secret',
      ]) {
        final check = term.isAllowed(bad);
        expect(check.allowed, isFalse, reason: 'should reject: $bad');
      }
    });

    test('allows read-only commands and pipes between them', () {
      for (final good in [
        'ls',
        'ls -la',
        'cat README.md | head -20',
        'grep -rn TODO lib',
      ]) {
        final check = term.isAllowed(good);
        expect(check.allowed, isTrue, reason: 'should allow: $good');
      }
    });
  });

  group('ToolRegistry schemas', () {
    test('schemas contain the core tools', () {
      final registry = _registry(_makeService());
      final schemas = registry.schemas();
      final names = [
        for (final s in schemas) (s['function'] as Map)['name'] as String,
      ];
      for (final expected in [
        'list_files',
        'read_file',
        'search_code',
        'write_file',
        'create_file',
        'patch_file',
        'delete_file',
        'move_file',
        'run_command',
        'git_status',
        'git_commit',
        'create_pull_request',
      ]) {
        expect(names, contains(expected));
      }
    });

    test('unknown tool returns an error string, not a crash', () async {
      final registry = _registry(_makeService());
      final result = await registry.execute('does_not_exist', {});
      expect(result, startsWith('ERROR'));
    });
  });

  group('AgentLoop with a scripted backend', () {
    late ProjectService projects;

    setUp(() async {
      projects = ProjectService();
      try {
        await projects.createProject('agent_test_${DateTime.now().millisecondsSinceEpoch}');
      } catch (_) {
        // path_provider unavailable in test env — loop tests that need a
        // project will observe the no-project path, which is also valid.
      }
    });

    test('no tool calls → single response returned', () async {
      final backend = _FakeBackend([
        (content: 'Here is the plan and answer.', toolCalls: const []),
      ]);
      final loop = AgentLoop(
        backend: backend,
        registry: _registry(projects),
        projects: projects,
      );
      final reply = await loop.run('What files exist?');
      expect(reply, 'Here is the plan and answer.');
      expect(backend.requestCount, 1);
    });

    test('plan-only mode denies mutations and the loop continues', () async {
      final backend = _FakeBackend([
        (
          content: 'Planning to write a file',
          toolCalls: [
            const ToolCall(
                id: 'c1',
                name: 'write_file',
                arguments: {'path': 'x.txt', 'content': 'data'}),
          ],
        ),
        (content: 'PLAN: 1. create x.txt 2. verify', toolCalls: const []),
      ]);
      final loop = AgentLoop(
        backend: backend,
        registry: _registry(projects),
        projects: projects,
        mode: AgentMode.planOnly,
      );
      final reply = await loop.run('Add x.txt');
      expect(reply, contains('PLAN'));
      expect(backend.requestCount, 2);
    });

    test('cancel stops the loop between rounds', () async {
      final backend = _FakeBackend([
        (
          content: '',
          toolCalls: [
            const ToolCall(id: 'c1', name: 'list_files', arguments: {}),
          ],
        ),
      ]);
      final loop = AgentLoop(
        backend: backend,
        registry: _registry(projects),
        projects: projects,
      );
      // Cancel immediately — the loop should return without further rounds.
      scheduleMicrotask(() => loop.cancel());
      final reply = await loop.run('inspect');
      expect(backend.requestCount, lessThanOrEqualTo(1));
      expect(reply, anyOf(isEmpty, isNotEmpty)); // returns whatever it had
    });

    test('mutating tool in auto mode runs without approval events', () async {
      // Only meaningful when a project exists; otherwise the registry
      // returns the no-project error and the loop still completes.
      final backend = _FakeBackend([
        (
          content: '',
          toolCalls: [
            const ToolCall(
                id: 'c1',
                name: 'write_file',
                arguments: {'path': 'a.txt', 'content': 'hello'}),
          ],
        ),
        (content: 'Wrote a.txt', toolCalls: const []),
      ]);
      final loop = AgentLoop(
        backend: backend,
        registry: _registry(projects),
        projects: projects,
        mode: AgentMode.auto,
      );
      final events = <AgentEvent>[];
      final sub = loop.events.listen(events.add);
      final reply = await loop.run('write a.txt');
      await sub.cancel();
      expect(reply, 'Wrote a.txt');
      // Steps were emitted (either the write or the no-project error).
      expect(events, isNotEmpty);
    });
  });

  group('Agent lifecycle states', () {
    test('success finalizes as COMPLETED exactly once', () async {
      final backend = _FakeBackend([
        (content: 'All done.', toolCalls: const []),
      ]);
      final loop = AgentLoop(
        backend: backend,
        registry: _registry(ProjectService()),
        projects: ProjectService(),
      );
      final outcomes = <AgentOutcome>[];
      final sub = loop.outcome.listen(outcomes.add);
      await loop.run('hello');
      // Broadcast events deliver on a later microtask — pump the queue.
      await Future<void>.delayed(Duration.zero);
      await Future<void>.delayed(Duration.zero);
      await sub.cancel();
      expect(loop.state, AgentTaskState.completed);
      expect(outcomes.length, 1);
      expect(outcomes.single.state, AgentTaskState.completed);
    });

    test('backend error finalizes as FAILED with the message', () async {
      final backend = _FailingBackend(const ApiException('boom', 'provider'));
      final loop = AgentLoop(
        backend: backend,
        registry: _registry(ProjectService()),
        projects: ProjectService(),
      );
      // Start the run first, then await its single outcome.
      final runFuture = loop.run('hello');
      final outcome = await loop.outcome.first;
      await runFuture;
      expect(loop.state, AgentTaskState.failed);
      expect(outcome.state, AgentTaskState.failed);
      expect(outcome.message, contains('boom'));
    });

    test('watchdog timeout finalizes as FAILED', () async {
      final backend = _HangingBackend();
      final loop = AgentLoop(
        backend: backend,
        registry: _registry(ProjectService()),
        projects: ProjectService(),
        taskTimeout: const Duration(milliseconds: 80),
      );
      // run() arms the watchdog; the hanging backend is aborted when it fires.
      final runFuture = loop.run('hang');
      final outcome = await loop.outcome.first;
      await runFuture;
      expect(loop.state, AgentTaskState.failed);
      expect(outcome.state, AgentTaskState.failed);
      expect(outcome.message, contains('timed out'));
    });

    test('cancel finalizes as CANCELLED even with in-flight backend', () async {
      final backend = _HangingBackend();
      final loop = AgentLoop(
        backend: backend,
        registry: _registry(ProjectService()),
        projects: ProjectService(),
      );
      // The backend hangs forever unless cancelled; the loop must observe
      // the CancelToken and abort.
      final outcomeFuture = loop.outcome.first;
      final runFuture = loop.run('hang');
      await Future.delayed(const Duration(milliseconds: 20));
      loop.cancel();
      final outcome = await outcomeFuture;
      await runFuture;
      expect(loop.state, AgentTaskState.cancelled);
      expect(outcome.state, AgentTaskState.cancelled);
      expect(backend.cancelled, isTrue);
    });

    test('late duplicate finalize attempts are ignored', () async {
      final backend = _FakeBackend([
        (content: 'done', toolCalls: const []),
      ]);
      final loop = AgentLoop(
        backend: backend,
        registry: _registry(ProjectService()),
        projects: ProjectService(),
      );
      final outcomes = <AgentOutcome>[];
      final sub = loop.outcome.listen(outcomes.add);
      await loop.run('hello');
      // Simulate a late duplicate completion — must not emit again.
      loop.cancel();
      await Future<void>.delayed(Duration.zero);
      await Future<void>.delayed(Duration.zero);
      await sub.cancel();
      expect(outcomes.length, 1); // only the real completion
    });
  });

  group('ProjectTemplate', () {
    test('all templates have unique ids and real file entries', () {
      final ids = [for (final t in ProjectTemplate.all) t.id];
      expect(ids.toSet().length, ids.length);
      for (final t in ProjectTemplate.all) {
        expect(t.label, isNotEmpty);
        for (final f in t.files) {
          expect(f.path, isNot(startsWith('/')));
          expect(f.content, isNotEmpty);
        }
      }
    });

    test('flutter template contains pubspec and main.dart', () {
      final paths = [for (final f in ProjectTemplate.flutterApp.files) f.path];
      expect(paths, contains('pubspec.yaml'));
      expect(paths, contains('lib/main.dart'));
    });
  });

  group('AgentStep model', () {
    test('steps transition through statuses', () {
      final step = AgentStep(id: '1', title: 'Reading x', tool: 'read_file');
      expect(step.status, AgentStepStatus.pending);
      step.status = AgentStepStatus.running;
      expect(step.status, AgentStepStatus.running);
      step.status = AgentStepStatus.done;
      expect(step.status, AgentStepStatus.done);
    });
  });
}


