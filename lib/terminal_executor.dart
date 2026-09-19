import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import 'api_client.dart' show CancelToken;

/// Real shell execution on Android, inside the project directory.
///
/// Reality on a stock Android device: `sh`/`toybox` exist, so many
/// read-only commands genuinely work (ls, cat, grep, find, wc, head, tail,
/// sort, uniq, sed -n, ps, df, du, date, whoami, echo, printf, tar, unzip…).
/// Compilers and SDK toolchains (flutter, gradle, npm, dart, java, python)
/// are NOT present on-device — those commands exit with a clear
/// "not found" that is reported honestly to the model instead of being
/// hidden or faked.
class TerminalExecutor {
  /// Substrings that make a command flat-out rejected. These can escape the
  /// sandbox, destroy data outside the project, or require privileges the
  /// app sandbox does not have.
  static const _deny = [
    'rm -rf /',
    'watch ',
    'mkfs',
    'dd if=',
    ':(){ :|:&',
    'chmod 777 /',
    'chown',
    'su ',
    'sudo',
    'reboot',
    'shutdown',
    'mount',
    'umount',
    'pm install',
    'am start',
    'settings put',
    'getevent',
    'sendevent',
    'iptables',
    '>',
    '>>',
    '|',
    ';',
    '&&',
    '||',
    '`',
    '\$(',
  ];

  /// Commands allowed even though they appear in [_deny] as substrings
  /// (e.g. pipes are fine for read-only pipelines the model may need).
  static const _denyWhitelist = ['|', '>', '>>'];

  final Duration timeout;

  TerminalExecutor({this.timeout = const Duration(seconds: 30)});

  ({bool allowed, String? reason}) isAllowed(String command) {
    final trimmed = command.trim();
    if (trimmed.isEmpty) return (allowed: false, reason: 'Empty command.');
    for (final d in _deny) {
      if (_denyWhitelist.contains(d)) continue; // handled below
      if (trimmed.contains(d)) {
        return (allowed: false, reason: 'Command rejected for safety: contains "$d".');
      }
    }
    // Blocking waits waste the task budget — the agent must poll with
    // tools (e.g. ci_status) instead of `sleep 180`. Match the command
    // word precisely so `grep sleep lib` still works.
    if (RegExp(r'(^|[;&|]\s*)sleep(\s|$)').hasMatch(trimmed)) {
      return (allowed: false,
          reason: 'sleep is not allowed — poll with tools instead '
              '(e.g. ci_status with wait:true) instead of waiting blindly.');
    }
    // Redirection: only reject writing OUTSIDE the project is hard to prove
    // in a shell string; simplest honest policy is to disallow redirects and
    // let the model use write_file instead.
    if (trimmed.contains('>') || trimmed.contains('<')) {
      return (allowed: false,
          reason: 'Shell redirection is not allowed — use write_file/read_file tools instead.');
    }
    // Pipes ARE allowed for read-only text processing, but each stage must
    // still avoid the denylist and must not read outside the project.
    for (final stage in trimmed.split('|')) {
      final s = stage.trim();
      if (s.isEmpty) return (allowed: false, reason: 'Empty command stage.');
      for (final d in _deny) {
        if (d == '|') continue;
        if (s.contains(d)) {
          return (allowed: false, reason: 'Command rejected for safety: stage contains "$d".');
        }
      }
      // Absolute paths in arguments read outside the project sandbox.
      final abs = RegExp(r'(?<![\w-])/(?:etc|proc|sys|data|system|dev)\b');
      if (abs.hasMatch(s)) {
        return (allowed: false,
            reason: 'Commands may only access files inside the project '
                '(no /etc, /proc, /sys, /data, /system, /dev paths).');
      }
    }
    return (allowed: true, reason: null);
  }

  /// Run [command] with cwd = the open project root.
  ///
  /// Cancellation: [cancelToken] kills the subprocess immediately (user
  /// Stop, or the loop's step watchdog). Timeout kills it too and reports
  /// timedOut=true. Returns (exitCode, stdout+stderr merged, wasTimedOut).
  Future<({int exitCode, String output, bool timedOut})> run(
      String command, String cwd,
      {CancelToken? cancelToken}) async {
    final check = isAllowed(command);
    if (!check.allowed) {
      return (exitCode: 126, output: check.reason ?? 'Command rejected.', timedOut: false);
    }
    try {
      final proc = await Process.start(
        '/system/bin/sh',
        ['-c', command],
        workingDirectory: cwd,
        environment: {
          'PATH':
              '/system/bin:/system/xbin:/vendor/bin:/product/bin:/odm/bin',
          'HOME': cwd,
          'TMPDIR': p.join(cwd, '.tmp'),
          'LANG': 'en_US.UTF-8',
        },
        mode: ProcessStartMode.normal,
      );
      final out = <int>[];
      final err = <int>[];
      var killed = false;
      void kill() {
        if (killed) return;
        killed = true;
        proc.kill(ProcessSignal.sigkill);
      }

      final timer = Timer(timeout, kill);
      final cancelSub =
          cancelToken?.future.then((_) => kill());
      final stdSub = proc.stdout.listen(out.addAll);
      final errSub = proc.stderr.listen(err.addAll);
      final code = await proc.exitCode;
      timer.cancel();
      await stdSub.asFuture<void>();
      await errSub.asFuture<void>();
      await cancelSub;
      var text = utf8Safe(out) + utf8Safe(err);
      if (text.length > 8000) {
        text = '${text.substring(0, 8000)}\n… (output truncated)';
      }
      return (
        exitCode: killed ? -9 : code,
        output: text.trim(),
        timedOut: killed,
      );
    } on ProcessException catch (e) {
      return (
        exitCode: 127,
        output: 'Shell unavailable on this device: ${e.message}',
        timedOut: false,
      );
    }
  }

  static String utf8Safe(List<int> bytes) {
    try {
      return utf8.decode(bytes, allowMalformed: true);
    } catch (_) {
      return '(binary output)';
    }
  }
}
