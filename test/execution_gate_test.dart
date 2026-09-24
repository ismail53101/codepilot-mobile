import 'package:flutter_test/flutter_test.dart';

import 'package:codepilot_mobile/execution_gate.dart';

void main() {
  group('firstBinary', () {
    test('strips env prefixes and paths', () {
      expect(firstBinary('sed -n 1,5p lib/x.dart'), 'sed');
      expect(firstBinary('FOO=1 bar --baz'), 'bar');
      expect(firstBinary('/usr/bin/grep -r x'), 'grep');
      expect(firstBinary('   '), '');
    });
  });

  group('classifyCommandFailure', () {
    test('success is not a failure', () {
      expect(
        classifyCommandFailure(command: 'ls', exitCode: 0, output: ''),
        FailureKind.notFailure,
      );
    });

    test('sed/head/tail/grep/wc are environment limitations (sandbox lacks them)',
        () {
      for (final bin in ['sed', 'head', 'tail', 'grep', 'wc']) {
        final kind = classifyCommandFailure(
          command: '$bin something',
          exitCode: 127,
          output: 'sh: $bin: not found',
        );
        expect(kind, FailureKind.environmentLimitation, reason: bin);
      }
    });

    test('command-not-found phrases are environment limitations', () {
      expect(
        classifyCommandFailure(
            command: 'frobnicate --x', exitCode: 127, output: 'sh: frobnicate: not found'),
        FailureKind.environmentLimitation,
      );
      expect(
        classifyCommandFailure(
            command: 'widget', exitCode: 126, output: 'permission denied'),
        FailureKind.environmentLimitation,
      );
    });

    test('known absent toolchains are environment limitations even with output',
        () {
      for (final bin in ['make', 'flutter', 'dart', 'npm', 'gradle']) {
        final kind = classifyCommandFailure(
          command: '$bin check',
          exitCode: 2,
          output: 'Error 1',
        );
        expect(kind, FailureKind.environmentLimitation, reason: bin);
      }
    });

    test('a genuinely failing project tool is a project failure', () {
      expect(
        classifyCommandFailure(
            command: 'sh build.sh', exitCode: 2, output: 'Compilation failed'),
        FailureKind.projectFailure,
      );
    });

    test('parseCommandResult handles all executor shapes', () {
      expect(parseCommandResult('exit=0\nall good').exitCode, 0);
      expect(parseCommandResult('exit=2\nmake: Error 1').exitCode, 2);
      expect(
          parseCommandResult('exit=2\nmake: Error 1').output, 'make: Error 1');
      expect(parseCommandResult('exit=timeout\nbuild killed').exitCode, 124);
      expect(parseCommandResult('ERROR: file not found: x.dart').exitCode, 1);
      expect(
        parseCommandResult('DENIED: the user declined').output,
        startsWith('DENIED'),
      );
      expect(parseCommandResult('plain output').exitCode, 0);
    });

    test('classifyToolResult separates policy, env and project failures', () {
      expect(
        classifyToolResult('run_command', 'exit=2\nsh: build.sh: cannot open',
            command: 'sh build.sh'),
        FailureKind.projectFailure,
      );
      expect(
        classifyToolResult('run_command',
            'exit=127\nsh: sed: not found',
            command: "sed -n '1,5p' lib/a.dart"),
        FailureKind.environmentLimitation,
      );
      expect(
        classifyToolResult('run_command',
            'exit=126\nCommand rejected for safety: contains "chown".',
            command: 'chown x'),
        FailureKind.policyRejection,
      );
      expect(
        classifyToolResult('run_command',
            'exit=126\nShell redirection is not allowed — use write_file.',
            command: 'echo hi > f.txt'),
        FailureKind.policyRejection,
      );
      expect(
        classifyToolResult('run_command', 'exit=0\nfile contents here',
            command: 'cat lib/a.dart'),
        FailureKind.notFailure,
      );
      expect(
        classifyToolResult('read_file', 'ERROR: file not found: x.dart'),
        FailureKind.projectFailure,
      );
    });

    test('policy rejection is distinct from env/project failure', () {
      expect(isPolicyRejection('Command rejected for safety: rm -rf'),
          isTrue);
      expect(isPolicyRejection('ERROR: exit=1 make'), isFalse);
    });
  });

  group('nativeFallbackFor', () {
    test('sed with a file maps to read_file', () {
      final fb = nativeFallbackFor("sed -n '110,220p' lib/agent_loop.dart");
      expect(fb, isNotNull);
      expect(fb!.tool, 'read_file');
      expect(fb.args['path'], 'lib/agent_loop.dart');
      expect(fb.note, contains('110-220'));
    });

    test('grep maps to search_code with the pattern', () {
      final fb = nativeFallbackFor("grep -rn 'onGenerateRoute' lib/");
      expect(fb, isNotNull);
      expect(fb!.tool, 'search_code');
      expect(fb.args['query'], contains('onGenerateRoute'));
      expect(fb.args['regex'], 'true');
    });

    test('head/tail map to read_file', () {
      expect(nativeFallbackFor('head -5 README.md')!.tool, 'read_file');
      expect(nativeFallbackFor('tail -n 20 lib/main.dart')!.tool, 'read_file');
    });

    test('ls/find map to list_files', () {
      expect(nativeFallbackFor('find . -name "*.dart"')!.tool, 'list_files');
      expect(nativeFallbackFor('ls')!.tool, 'list_files');
      expect(nativeFallbackFor('ls lib')!.tool, 'list_files');
      expect(nativeFallbackFor('find lib -name x')!.args['path'], 'lib');
      // The bare '.' operand must NOT be treated as a file target.
      expect(nativeFallbackFor('find . -name x')!.args, isEmpty);
    });

    test('wc with a file maps to read_file, without to list_files', () {
      expect(nativeFallbackFor('wc -l lib/a.dart')!.tool, 'read_file');
      expect(nativeFallbackFor('wc -l lib/a.dart')!.args['path'], 'lib/a.dart');
      expect(nativeFallbackFor('wc -l')!.tool, 'list_files');
    });

    test('unmappable commands return null', () {
      expect(nativeFallbackFor('curl https://example.com'), isNull);
      expect(nativeFallbackFor(''), isNull);
    });
  });

  group('validateSyntax', () {
    test('balanced Dart file passes', () {
      final r = validateSyntax([
        (
          path: 'lib/a.dart',
          content: 'void f() { print("hi } {"); } // } unbalanced? no\n'
        ),
      ]);
      expect(r.ok, isTrue);
    });

    test('unbalanced brace fails with the file name', () {
      final r = validateSyntax([
        (path: 'lib/broken.dart', content: 'void f() { if (x) { g(); }\n'),
      ]);
      expect(r.ok, isFalse);
      expect(r.issues.single.file, 'lib/broken.dart');
      expect(r.summary, contains('broken.dart'));
    });

    test('braces inside strings and comments do not false-positive', () {
      final r = validateSyntax([
        (
          path: 'lib/c.dart',
          content: '// } {\n/* } */\nfinal s = "\u007b\u007b";\n'
        ),
      ]);
      expect(r.ok, isTrue);
    });

    test('non-source files are ignored', () {
      final r = validateSyntax([
        (path: 'assets/notes.md', content: '{{{ no braces check here'),
      ]);
      expect(r.ok, isTrue);
    });
  });

  group('failure bookkeeping (record/resolve/reclassify)', () {
    test('resolveFailure removes the entry by id', () {
      final failures = <UnresolvedFailure>[];
      recordFailure(failures, 't1',
          const UnresolvedFailure('t1', 'run_command', 'exit=2 make: Error 1',
              FailureKind.projectFailure));
      expect(failures, hasLength(1));
      resolveFailure(failures, 't1');
      expect(failures, isEmpty);
    });

    test('recordFailure replaces a previous entry for the same id', () {
      final failures = <UnresolvedFailure>[];
      recordFailure(failures, 't1', const UnresolvedFailure('t1', 'run_command',
          'exit=1 (no classification available)', FailureKind.projectFailure));
      recordFailure(failures, 't1', const UnresolvedFailure('t1', 'run_command',
          'exit=2 make: Error 1', FailureKind.projectFailure));
      expect(failures, hasLength(1));
      expect(failures.single.detail, contains('exit=2'));
    });

    test('distinct call ids stay distinct', () {
      final failures = <UnresolvedFailure>[];
      recordFailure(failures, 't1', const UnresolvedFailure('t1', 'run_command',
          'exit=2 first', FailureKind.projectFailure));
      recordFailure(failures, 't2', const UnresolvedFailure('t2', 'run_command',
          'exit=2 second', FailureKind.projectFailure));
      expect(failures, hasLength(2));
      resolveFailure(failures, 't1');
      expect(failures.single.id, 't2');
    });

    test('reclassifyFailure corrects kind and detail', () {
      final failures = <UnresolvedFailure>[];
      recordFailure(failures, 't1', const UnresolvedFailure('t1', 'run_command',
          'exit=1 (no classification available)', FailureKind.projectFailure));
      reclassifyFailure(failures, 't1', FailureKind.environmentLimitation,
          detail: 'sh: sed: not found');
      expect(failures.single.kind, FailureKind.environmentLimitation);
      expect(failures.single.detail, contains('sed'));
    });

    test('reclassifyFailure on an unknown id is a no-op', () {
      final failures = <UnresolvedFailure>[];
      reclassifyFailure(failures, 'missing', FailureKind.projectFailure,
          detail: 'x');
      expect(failures, isEmpty);
    });

    test('env-limitation failures do not block completion once resolved', () {
      // Simulates the loop: sed fails (env), is recovered by read_file, then
      // the gate runs — no blocker.
      final failures = <UnresolvedFailure>[
        const UnresolvedFailure('t1', 'run_command', 'sh: sed: not found',
            FailureKind.environmentLimitation),
      ];
      resolveFailure(failures, 't1');
      final v = evaluateCompletionGate(GateEvidence(
        unresolvedFailures: failures,
        deliveryRequested: false,
      ));
      expect(v, isA<GatePassed>());
    });
  });

  group('evaluateCompletionGate', () {
    const base = GateEvidence();

    test('passes with no evidence', () {
      final v = evaluateCompletionGate(base);
      expect(v, isA<GatePassed>());
    });

    test('unrecovered failed steps block completion', () {
      final v = evaluateCompletionGate(base.copyWith(
        unresolvedFailures: const [
          UnresolvedFailure('1', 'run_command', 'ERROR: exit=2 make',
              FailureKind.projectFailure),
        ],
      ));
      expect(v, isA<GateBlocked>());
      expect((v as GateBlocked).reason, contains('Actionable project errors'));
    });

    test('validation failure blocks completion', () {
      final v = evaluateCompletionGate(base.copyWith(
        validation:
            const ValidationResult(false, [ValidationIssue('a.dart', 'unbalanced "{"')], 'Syntax validation failed'),
      ));
      expect(v, isA<GateBlocked>());
      expect((v as GateBlocked).reason, contains('Validation failed'));
    });

    test('edits + delivery requested + no commit blocks completion', () {
      final v = evaluateCompletionGate(base.copyWith(
        writtenFiles: const [
          (tool: 'write_file', path: 'lib/x.dart', kind: 'write')
        ],
        deliveryRequested: true,
        repoLinked: true,
      ));
      expect(v, isA<GateBlocked>());
      expect((v as GateBlocked).reason, contains('no commit was created'));
    });

    test('RED CI blocks completion', () {
      final d = _delivery(ci: 'failure');
      final v = evaluateCompletionGate(base.copyWith(
        delivery: d,
        deliveryRequested: true,
        repoLinked: true,
      ));
      expect(v, isA<GateBlocked>());
      expect((v as GateBlocked).reason, contains('RED'));
    });

    test('missing remote commit blocks completion', () {
      final d = _delivery(head: 'b' * 40);
      final v = evaluateCompletionGate(base.copyWith(
        delivery: d,
        deliveryRequested: true,
        repoLinked: true,
      ));
      expect(v, isA<GateBlocked>());
      expect((v as GateBlocked).reason, contains('remote commit is missing'));
    });

    test('CI pending with workflows blocks completion', () {
      final d = _delivery();
      final v = evaluateCompletionGate(base.copyWith(
        delivery: d,
        deliveryRequested: true,
        repoLinked: true,
        repoHasWorkflows: true,
      ));
      expect(v, isA<GateBlocked>());
      expect((v as GateBlocked).reason, contains('CI has not reported'));
    });

    test('commit + verified remote + GREEN CI passes', () {
      final d = _delivery(ci: 'success');
      final v = evaluateCompletionGate(base.copyWith(
        delivery: d,
        deliveryRequested: true,
        repoLinked: true,
        repoHasWorkflows: true,
      ));
      expect(v, isA<GatePassed>());
      expect((v as GatePassed).evidence, contains('CI GREEN'));
    });

    test('delivery requested without a linked repo is blocked', () {
      final v = evaluateCompletionGate(base.copyWith(deliveryRequested: true));
      expect(v, isA<GateBlocked>());
      expect((v as GateBlocked).reason, contains('no GitHub repository'));
    });

    test('no workflows + verified push passes without CI demand', () {
      final d = _delivery();
      final v = evaluateCompletionGate(base.copyWith(
        delivery: d,
        deliveryRequested: true,
        repoLinked: true,
        repoHasWorkflows: false,
      ));
      expect(v, isA<GatePassed>());
    });
  });

  group('ciFailureRepairInstruction', () {
    test('embeds the real log and the repair protocol', () {
      final sha = 'a' * 40;
      final s = ciFailureRepairInstruction(
        CiVerdict(
            status: 'completed',
            conclusion: 'failure',
            headSha: sha,
            logExcerpt: 'Analyzing lib/main.dart...\nerror • expected'),
        'main',
        sha,
      );
      expect(s, contains('CI FAILED'));
      expect(s, contains('error • expected'));
      expect(s, contains('ci_status'));
    });

    test('truncates very long logs', () {
      final sha = 'a' * 40;
      final s = ciFailureRepairInstruction(
        CiVerdict(
            status: 'completed',
            conclusion: 'failure',
            logExcerpt: 'x' * 20000),
        'main',
        sha,
      );
      expect(s, contains('truncated'));
    });
  });
}

DeliveryRecord _delivery({String? head, String? ci}) => DeliveryRecord(
      commitSha: 'a' * 40,
      remoteHeadSha: head ?? 'a' * 40,
      ciConclusion: ci,
    );
