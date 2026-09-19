import 'dart:io';

import 'github_service.dart';
import 'models.dart';
import 'project_service.dart';
import 'terminal_executor.dart';

/// One OpenAI function-calling tool definition + its Dart executor.
class AgentTool {
  final String name;
  final String description;
  final Map<String, dynamic> parameters; // JSON Schema
  final Future<String> Function(Map<String, dynamic> args) execute;

  const AgentTool({
    required this.name,
    required this.description,
    required this.parameters,
    required this.execute,
  });

  Map<String, dynamic> toSchema() => {
        'type': 'function',
        'function': {
          'name': name,
          'description': description,
          'parameters': parameters,
        },
      };
}

/// Central registry: builds every tool against the open workspace.
/// All LLM filesystem/shell/git access goes through here — the model never
/// receives arbitrary filesystem access.
class ToolRegistry {
  final ProjectService projects;
  final GitHubService github;
  final TerminalExecutor terminal;
  final GitHubProjectStore repoStore;

  /// Optional extra gate (kept for direct registry users). The AgentLoop
  /// handles ask-mode approvals itself and leaves this unset.
  Future<bool> Function(String toolName, Map<String, dynamic> args)?
      approvalGate;

  ToolRegistry({
    required this.projects,
    required this.github,
    required this.repoStore,
    TerminalExecutor? terminal,
  }) : terminal = terminal ?? TerminalExecutor();

  bool get _hasProject {
    try {
      projects.root;
      return true;
    } on ProjectException {
      return false;
    }
  }

  String _noProject() =>
      'ERROR: no project is open. Ask the user to import one first '
      '(Home → File → ZIP, or Integrations → GitHub → Import).';

  /// Validate a tool-supplied path BEFORE it reaches the filesystem:
  /// relative, no traversal, no leading repo-name folder (a real mistake
  /// models make — they re-create the GitHub zipball's top folder inside
  /// the project), no absolute paths.
  ({bool ok, String? error, String path}) _checkPath(String raw) {
    var path = raw.trim().replaceAll('\\\\', '/');
    if (path.isEmpty) return (ok: false, error: 'empty path', path: path);
    if (path.startsWith('/') || RegExp(r'^[A-Za-z]:').hasMatch(path)) {
      return (ok: false, error: 'absolute paths are not allowed', path: path);
    }
    final segs = path.split('/').where((s) => s.isNotEmpty && s != '.').toList();
    if (segs.any((s) => s == '..')) {
      return (ok: false, error: 'path traversal (..) is not allowed', path: path);
    }
    // Strip a leading folder named after the repo/zipball (e.g.
    // "owner-repo-sha/lib/x.dart" when the project root IS that repo).
    final manifestHint = projects.projectName ?? '';
    if (segs.isNotEmpty &&
        segs.first.contains('-') &&
        (manifestHint.isEmpty || segs.first != manifestHint) &&
        segs.length > 1 &&
        (segs.first.startsWith('ismail') || segs.first.contains(RegExp(r'-[0-9a-f]{7,}$')))) {
      path = segs.skip(1).join('/');
    }
    return (ok: true, error: null, path: path);
  }

  List<AgentTool> buildTools() => [
        _listFiles(),
        _readFile(),
        _searchCode(),
        _writeFile(),
        _createFile(),
        _patchFile(),
        _deleteFile(),
        _moveFile(),
        _runCommand(),
        _gitStatus(),
        _gitCommit(),
        _createBranch(),
        _gitPush(),
        _createPullRequest(),
        _ciStatus(),
      ];

  Map<String, dynamic> schemas() => [for (final t in buildTools()) t.toSchema()];

  /// Execute a tool call by name. Returns the string result for the model.
  Future<String> execute(String name, Map<String, dynamic> args) async {
    for (final t in buildTools()) {
      if (t.name == name) {
        try {
          return await t.execute(args);
        } on ProjectException catch (e) {
          return 'ERROR: ${e.message}';
        } on GitHubException catch (e) {
          return 'ERROR: ${e.message}';
        } on FileSystemException catch (e) {
          return 'ERROR: filesystem: ${e.message}';
        }
      }
    }
    return 'ERROR: unknown tool "$name".';
  }

  // ------------------------------------------------------------------
  // Read tools
  // ------------------------------------------------------------------

  AgentTool _listFiles() => AgentTool(
        name: 'list_files',
        description:
            'List files/directories. Pass a path to list one directory; '
            'omit path for the full project tree (relative paths).',
        parameters: {
          'type': 'object',
          'properties': {
            'path': {'type': 'string', 'description': 'Directory path, optional.'}
          },
        },
        execute: (args) async {
          if (!_hasProject) return _noProject();
          final path = args['path'] as String?;
          if (path == null || path.isEmpty || path == '.') {
            final nodes = projects.fileTree();
            final buf = StringBuffer();
            for (final n in nodes.take(300)) {
              buf.writeln('${n.isDir ? "[dir] " : "      "}${n.path}');
            }
            if (nodes.length > 300) buf.writeln('… (+${nodes.length - 300} more)');
            return buf.toString().trim();
          }
          final nodes = projects.listDir(path);
          if (nodes.isEmpty) return '(empty directory)';
          return [
            for (final n in nodes) '${n.isDir ? "[dir] " : "      "}${n.path}'
          ].join('\n');
        },
      );

  AgentTool _readFile() => AgentTool(
        name: 'read_file',
        description:
            'Read a file from the project. Returns up to 12,000 characters.',
        parameters: {
          'type': 'object',
          'properties': {
            'path': {
              'type': 'string',
              'description': 'File path relative to the project root.'
            }
          },
          'required': ['path'],
        },
        execute: (args) async {
          if (!_hasProject) return _noProject();
          final check = _checkPath(args['path'] as String? ?? '');
          if (!check.ok) return 'ERROR: invalid path: ${check.error}';
          final content = projects.readFile(check.path);
          if (content == null) return 'ERROR: file not found: ${check.path}';
          return content.length > 12000
              ? '${content.substring(0, 12000)}\n… (truncated at 12000 chars)'
              : content;
        },
      );

  AgentTool _searchCode() => AgentTool(
        name: 'search_code',
        description:
            'Search file contents (case-insensitive substring or regex). '
            'Returns "path:line: text" matches.',
        parameters: {
          'type': 'object',
          'properties': {
            'query': {'type': 'string'},
            'regex': {'type': 'boolean', 'description': 'Treat query as a regex.'},
          },
          'required': ['query'],
        },
        execute: (args) async {
          if (!_hasProject) return _noProject();
          final hits = projects.search(
            args['query'] as String? ?? '',
            regex: args['regex'] as bool? ?? false,
          );
          if (hits.isEmpty) return 'No matches.';
          final buf = StringBuffer();
          for (final h in hits.take(40)) {
            buf.writeln('${h.path}:${h.line}: ${h.text}');
          }
          if (hits.length > 40) buf.writeln('… (${hits.length - 40} more)');
          return buf.toString().trim();
        },
      );

  // ------------------------------------------------------------------
  // Write tools (subject to the approval gate)
  // ------------------------------------------------------------------

  Future<String> _guardedWrite(
      String toolName, Map<String, dynamic> args, Future<String> Function() act) async {
    if (!_hasProject) return _noProject();
    final gate = approvalGate;
    if (gate != null) {
      final allowed = await gate(toolName, args);
      if (!allowed) return 'DENIED: the user declined this change. Stop and explain.';
    }
    return act();
  }

  AgentTool _writeFile() => AgentTool(
        name: 'write_file',
        description:
            'Write COMPLETE new content to a file (creates or overwrites). '
            'Always pass the full file content, never a snippet.',
        parameters: {
          'type': 'object',
          'properties': {
            'path': {'type': 'string'},
            'content': {'type': 'string'},
          },
          'required': ['path', 'content'],
        },
        execute: (args) => _guardedWrite('write_file', args, () async {
          final check = _checkPath(args['path'] as String? ?? '');
          if (!check.ok) return 'ERROR: invalid path: ${check.error}';
          final path = check.path;
          final content = args['content'] as String? ?? '';
          final existed = projects.readFile(path) != null;
          projects.writeFile(path, content);
          await projects.recordChangeInManifest(path, existed ? 'M' : 'A');
          return 'OK: ${existed ? 'updated' : 'created'} $path '
              '(${content.split('\n').length} lines).';
        }),
      );

  AgentTool _createFile() => AgentTool(
        name: 'create_file',
        description: 'Create a NEW file. Fails if the file already exists.',
        parameters: {
          'type': 'object',
          'properties': {
            'path': {'type': 'string'},
            'content': {'type': 'string'},
          },
          'required': ['path', 'content'],
        },
        execute: (args) => _guardedWrite('create_file', args, () async {
          final check = _checkPath(args['path'] as String? ?? '');
          if (!check.ok) return 'ERROR: invalid path: ${check.error}';
          final path = check.path;
          final content = args['content'] as String? ?? '';
          if (projects.readFile(path) != null) {
            return 'ERROR: $path already exists — use write_file to overwrite.';
          }
          projects.writeFile(path, content);
          await projects.recordChangeInManifest(path, 'A');
          return 'OK: created $path (${content.split('\n').length} lines).';
        }),
      );

  AgentTool _patchFile() => AgentTool(
        name: 'patch_file',
        description:
            'Replace exact text inside an existing file. old_text must match '
            'the current file content EXACTLY (copy it from read_file output). '
            'Cheaper than rewriting a whole file.',
        parameters: {
          'type': 'object',
          'properties': {
            'path': {'type': 'string'},
            'old_text': {'type': 'string'},
            'new_text': {'type': 'string'},
          },
          'required': ['path', 'old_text', 'new_text'],
        },
        execute: (args) => _guardedWrite('patch_file', args, () async {
          final check = _checkPath(args['path'] as String? ?? '');
          if (!check.ok) return 'ERROR: invalid path: ${check.error}';
          final path = check.path;
          final oldText = args['old_text'] as String? ?? '';
          final newText = args['new_text'] as String? ?? '';
          final content = projects.readFile(path);
          if (content == null) return 'ERROR: file not found: $path';
          if (!content.contains(oldText)) {
            return 'ERROR: old_text not found in $path — re-read the file and '
                'copy the exact text (including whitespace).';
          }
          if (oldText == newText) {
            return 'ERROR: old_text and new_text are identical.';
          }
          final updated = content.replaceFirst(oldText, newText);
          projects.writeFile(path, updated);
          await projects.recordChangeInManifest(path, 'M');
          return 'OK: patched $path.';
        }),
      );

  AgentTool _deleteFile() => AgentTool(
        name: 'delete_file',
        description: 'Delete a file from the project. Use only when required.',
        parameters: {
          'type': 'object',
          'properties': {
            'path': {'type': 'string'}
          },
          'required': ['path'],
        },
        execute: (args) => _guardedWrite('delete_file', args, () async {
          final check = _checkPath(args['path'] as String? ?? '');
          if (!check.ok) return 'ERROR: invalid path: ${check.error}';
          final path = check.path;
          final content = projects.readFile(path);
          if (content == null) return 'ERROR: file not found: $path';
          projects.deleteFile(path);
          await projects.recordChangeInManifest(path, 'D');
          return 'OK: deleted $path.';
        }),
      );

  AgentTool _moveFile() => AgentTool(
        name: 'move_file',
        description: 'Rename or move a file within the project.',
        parameters: {
          'type': 'object',
          'properties': {
            'source': {'type': 'string'},
            'destination': {'type': 'string'},
          },
          'required': ['source', 'destination'],
        },
        execute: (args) => _guardedWrite('move_file', args, () async {
          final fromCheck = _checkPath(args['source'] as String? ?? '');
          final toCheck = _checkPath(args['destination'] as String? ?? '');
          if (!fromCheck.ok || !toCheck.ok) {
            return 'ERROR: invalid path: ${fromCheck.error ?? toCheck.error}';
          }
          final dest = projects.moveFile(fromCheck.path, toCheck.path);
          await projects.recordChangeInManifest(fromCheck.path, 'D');
          await projects.recordChangeInManifest(dest, 'A');
          return 'OK: moved ${fromCheck.path} → $dest.';
        }),
      );

  // ------------------------------------------------------------------
  // Terminal
  // ------------------------------------------------------------------

  AgentTool _runCommand() => AgentTool(
        name: 'run_command',
        description:
            'Run a shell command inside the project directory (Android toybox '
            'sh: ls, cat, grep, find, wc, head, tail, sort, sed -n, du, df…). '
            'Compilers/SDK toolchains (flutter, npm, python…) are NOT installed '
            'on-device and will fail with "not found" — use static analysis and '
            'file tools instead. Redirection is disabled; pipes between '
            'read-only stages are allowed. There is no timeout argument: '
            'commands are limited to 30 seconds.',
        parameters: {
          'type': 'object',
          'properties': {
            'command': {'type': 'string'},
          },
          'required': ['command'],
        },
        execute: (args) async {
          if (!_hasProject) return _noProject();
          final command = args['command'] as String? ?? '';
          final cwd = projects.rootPath!;
          final result = await terminal.run(command, cwd);
          final out = result.output.isEmpty ? '(no output)' : result.output;
          return 'exit=${result.exitCode}\n$out';
        },
      );

  // ------------------------------------------------------------------
  // Git (local status + real GitHub Git-Data commits)
  // ------------------------------------------------------------------

  AgentTool _gitStatus() => AgentTool(
        name: 'git_status',
        description:
            'Show changed files in the workspace compared to the import '
            'baseline (A=added, M=modified, D=deleted), plus the linked '
            'GitHub repository and branch when known.',
        parameters: {
          'type': 'object',
          'properties': const {},
        },
        execute: (args) async {
          if (!_hasProject) return _noProject();
          final changes = await projects.changedFilesSinceBaseline();
          final manifest = await projects.loadManifest();
          final git = projects.gitInfo();
          final buf = StringBuffer();
          buf.writeln('project: ${projects.projectName} (${projects.detectType()})');
          buf.writeln('remote: ${manifest['gitRepository'] ?? '(not linked)'}');
          buf.writeln('branch: ${manifest['gitBranch'] ?? git?.branch ?? '(unknown)'}');
          if (changes.isEmpty) {
            buf.write('working tree: clean (no changes since baseline)');
          } else {
            buf.writeln('changes: ${changes.length}');
            for (final c in changes) {
              buf.writeln('${c.status}  ${c.path}');
            }
          }
          return buf.toString().trim();
        },
      );

  /// Collect the full workspace snapshot for a real tree commit.
  Map<String, String?> _snapshotFiles() {
    final files = <String, String?>{};
    for (final node in projects.fileTree()) {
      if (node.isDir) continue;
      if (node.path == '.codepilot_manifest.json' ||
          node.path == '.codepilot_project') {
        continue;
      }
      files[node.path] = projects.readFile(node.path);
    }
    return files;
  }

  AgentTool _gitCommit() => AgentTool(
        name: 'git_commit',
        description:
            'Create a REAL git commit on GitHub from the current workspace '
            'snapshot. Requires a linked GitHub repository '
            '(gitRepository in the manifest, set by clone/import). '
            'The commit is created via the GitHub Git Data API.',
        parameters: {
          'type': 'object',
          'properties': {
            'message': {'type': 'string', 'description': 'Commit message.'},
            'branch': {
              'type': 'string',
              'description': 'Branch to commit to. Defaults to the linked branch.'
            },
          },
          'required': ['message'],
        },
        execute: (args) async {
          if (!_hasProject) return _noProject();
          final manifest = await projects.loadManifest();
          final repoFull = manifest['gitRepository'] as String?;
          if (repoFull == null) {
            return 'ERROR: no GitHub repository is linked to this project. '
                'Import it via Integrations → GitHub first.';
          }
          final parts = repoFull.split('/');
          if (parts.length != 2) return 'ERROR: malformed repository "$repoFull".';
          final repo = GitHubRepo(
            owner: parts[0],
            name: parts[1],
            defaultBranch: (manifest['gitBranch'] as String?) ?? 'main',
            privateRepo: false,
          );
          final branch = args['branch'] as String? ?? repo.defaultBranch;
          final gate = approvalGate;
          if (gate != null) {
            final ok = await gate('git_commit', args);
            if (!ok) return 'DENIED: the user declined the commit.';
          }
          final result = await github.commitTree(
            repo: repo,
            branch: branch,
            message: args['message'] as String? ?? 'CodePilot update',
            files: _snapshotFiles(),
          );
          await projects.updateManifest({
            'lastCommitSha': result.sha,
            'lastCommitUrl': result.htmlUrl,
            'gitBranch': branch,
          });
          await projects.snapshotBaseline();
          return 'OK: commit ${result.sha.substring(0, 8)} created on $branch\n'
              '${result.htmlUrl}';
        },
      );

  AgentTool _createBranch() => AgentTool(
        name: 'create_branch',
        description:
            'Create a new branch on the linked GitHub repository at the '
            'current head of the default branch (or a given sha).',
        parameters: {
          'type': 'object',
          'properties': {
            'name': {'type': 'string'},
          },
          'required': ['name'],
        },
        execute: (args) async {
          final manifest = await projects.loadManifest();
          final repoFull = manifest['gitRepository'] as String?;
          if (repoFull == null) return _noProjectLinked();
          final parts = repoFull.split('/');
          final repo = GitHubRepo(
            owner: parts[0],
            name: parts[1],
            defaultBranch: (manifest['gitBranch'] as String?) ?? 'main',
            privateRepo: false,
          );
          final name = args['name'] as String? ?? '';
          final sha = await github.createBranch(repo, name);
          await projects.updateManifest({'gitBranch': name});
          return 'OK: branch "$name" created at $sha.';
        },
      );

  String _noProjectLinked() =>
      'ERROR: no GitHub repository is linked. Import the repo first '
      '(Integrations → GitHub).';

  AgentTool _gitPush() => AgentTool(
        name: 'git_push',
        description:
            'Push the current workspace as a new commit to the linked '
            'repository/branch (equivalent to commit-with-default-message). '
            'Use git_commit with a meaningful message instead when possible.',
        parameters: {
          'type': 'object',
          'properties': {
            'message': {'type': 'string'},
          },
          'required': ['message'],
        },
        execute: (args) => execute('git_commit', {
          'message': args['message'] ?? 'CodePilot: push from mobile',
        }),
      );

  AgentTool _createPullRequest() => AgentTool(
        name: 'create_pull_request',
        description:
            'Open a pull request on the linked GitHub repository. '
            'head = your feature branch, base = the target branch.',
        parameters: {
          'type': 'object',
          'properties': {
            'head': {'type': 'string'},
            'base': {'type': 'string'},
            'title': {'type': 'string'},
            'body': {'type': 'string'},
          },
          'required': ['head', 'base', 'title'],
        },
        execute: (args) async {
          final manifest = await projects.loadManifest();
          final repoFull = manifest['gitRepository'] as String?;
          if (repoFull == null) return _noProjectLinked();
          final parts = repoFull.split('/');
          final repo = GitHubRepo(
            owner: parts[0],
            name: parts[1],
            defaultBranch: (manifest['gitBranch'] as String?) ?? 'main',
            privateRepo: false,
          );
          final pr = await github.createPullRequest(
            repo,
            args['head'] as String,
            args['base'] as String,
            args['title'] as String,
            body: args['body'] as String? ?? '',
          );
          return 'OK: PR #${pr.number} opened\n${pr.url}';
        },
      );

  AgentTool _ciStatus() => AgentTool(
        name: 'ci_status',
        description:
            'Check the latest GitHub Actions run for a branch. If the run '
            'failed, returns the failure log excerpt for error-driven repair.',
        parameters: {
          'type': 'object',
          'properties': {
            'branch': {'type': 'string'},
          },
        },
        execute: (args) async {
          final manifest = await projects.loadManifest();
          final repoFull = manifest['gitRepository'] as String?;
          if (repoFull == null) return _noProjectLinked();
          final parts = repoFull.split('/');
          final repo = GitHubRepo(
            owner: parts[0],
            name: parts[1],
            defaultBranch: (manifest['gitBranch'] as String?) ?? 'main',
            privateRepo: false,
          );
          final branch = args['branch'] as String? ?? repo.defaultBranch;
          final run = await github.latestRun(repo, branch);
          if (run == null) return 'No CI runs found for branch "$branch".';
          if (run.conclusion == 'failure') {
            final log = await github.fetchFailureLog(repo, run.runId);
            return 'CI FAILED on $branch (run ${run.runId})\n$log';
          }
          return 'CI on $branch: status=${run.status} conclusion=${run.conclusion ?? '-'}';
        },
      );
}

/// Per-session record of confirmed file writes for the final summary.
final agentHistory = AgentChangeLog();

class AgentChangeLog {
  final List<({String tool, String path, String kind})> _entries = [];
  void add(String tool, String path, String kind) =>
      _entries.add((tool: tool, path: path, kind: kind));
  void clear() => _entries.clear();
  List<({String tool, String path, String kind})> get entries =>
      List.unmodifiable(_entries);
  bool get isEmpty => _entries.isEmpty;
  void recordIfWrite(String tool, Map<String, dynamic> args) {
    final path = (args['path'] ?? args['source']) as String?;
    if (path != null) {
      add(tool, path, tool == 'delete_file' ? 'D' : 'M/A');
    }
  }
}
