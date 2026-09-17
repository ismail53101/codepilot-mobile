import 'dart:io';

import 'package:path/path.dart' as p;

import 'models.dart';
import 'project_service.dart';

/// The coding agent: tool functions over the open project plus a context
/// builder that sends ONLY relevant, size-limited file content to the API.
class AgentService {
  final ProjectService projects;
  final List<ChangeRecord> history = [];

  AgentService(this.projects);

  // ---------------- tools ----------------

  ToolResult readTool(String path) {
    try {
      final content = projects.readFile(path);
      if (content == null) return ToolResult('read_file', false, 'File not found: $path');
      final trimmed = content.length > 12000 ? '${content.substring(0, 12000)}\n… (truncated)' : content;
      return ToolResult('read_file', true, trimmed);
    } on ProjectException catch (e) {
      return ToolResult('read_file', false, e.message);
    }
  }

  ToolResult searchTool(String query) {
    try {
      final hits = projects.search(query);
      if (hits.isEmpty) return ToolResult('search_code', true, 'No matches for "$query".');
      final buf = StringBuffer();
      for (final h in hits.take(40)) {
        buf.writeln('${h.path}:${h.line}: ${h.text}');
      }
      if (hits.length > 40) buf.writeln('… (${hits.length - 40} more matches)');
      return ToolResult('search_code', true, buf.toString());
    } on ProjectException catch (e) {
      return ToolResult('search_code', false, e.message);
    }
  }

  /// Propose a write — returns the diff for confirmation. Does NOT touch disk.
  ProposedChange proposeWrite(String path, String newContent) {
    final before = projects.readFile(path) ?? '';
    final diff = projects.diffLines(before, newContent);
    return ProposedChange(
      kind: 'write',
      path: path,
      before: before,
      after: newContent,
      diff: diff,
      isNew: !File(p.join(projects.root.path, path)).existsSync(),
    );
  }

  /// Propose a delete — confirmation required by the UI before calling apply.
  ProposedChange proposeDelete(String path) {
    final before = projects.readFile(path) ?? '';
    return ProposedChange(
      kind: 'delete',
      path: path,
      before: before,
      after: '',
      diff: [for (final l in before.split('\n')) DiffLine('del', l)],
      isNew: false,
    );
  }

  /// Apply a previously confirmed proposal. Records it in history for undo.
  ChangeRecord applyChange(ProposedChange c) {
    if (c.kind == 'write') {
      projects.writeFile(c.path, c.after);
    } else if (c.kind == 'delete') {
      projects.deleteFile(c.path);
    } else {
      throw ProjectException('Unknown change kind: ${c.kind}');
    }
    final rec = ChangeRecord(
      id: DateTime.now().microsecondsSinceEpoch.toString(),
      time: DateTime.now(),
      kind: c.kind,
      path: c.path,
      contentBefore: c.kind == 'delete' ? c.before : null,
      contentAfter: c.kind == 'write' ? c.after : null,
    );
    history.add(rec);
    return rec;
  }

  /// Undo the latest (not already undone) change. Returns null if none.
  ChangeRecord? undoLast() {
    for (var i = history.length - 1; i >= 0; i--) {
      final rec = history[i];
      if (rec.undone) continue;
      if (rec.kind == 'write') {
        if (rec.contentBefore == null || rec.contentBefore!.isEmpty) {
          // file was created by the change → delete it
          if (projects.resolveFile(rec.path).existsSync()) projects.deleteFile(rec.path);
        } else {
          projects.writeFile(rec.path, rec.contentBefore!);
        }
      } else if (rec.kind == 'delete' && rec.contentBefore != null) {
        projects.writeFile(rec.path, rec.contentBefore!);
      }
      final undone = rec.markUndone();
      history[i] = undone;
      return undone;
    }
    return null;
  }

  List<ChangeRecord> recentChanges({int limit = 20}) =>
      history.reversed.take(limit).toList();

  // ---------------- context builder ----------------

  /// Build a compact, relevant context: project structure + ranked files.
  /// Ranks by path/name/query-term matches; hard-caps total characters so the
  /// whole project is NEVER sent.
  String buildContext({required String request, int maxChars = 24000}) {
    final buf = StringBuffer();
    final nodes = projects.fileTree();

    buf.writeln('PROJECT: ${projects.projectName} (${projects.detectType()})');
    buf.writeln('STRUCTURE:');
    for (final n in nodes.take(200)) {
      buf.writeln('${n.isDir ? "[dir] " : "      "}${n.path}');
    }
    if (nodes.length > 200) buf.writeln('… (+${nodes.length - 200} more entries)');

    // Rank files by relevance to the request.
    final terms = request
        .toLowerCase()
        .split(RegExp(r'[^a-z0-9_]+'))
        .where((t) => t.length > 2)
        .toSet();
    int score(FileNode n) {
      if (n.isDir) return -1;
      final lp = n.path.toLowerCase();
      var s = 0;
      for (final t in terms) {
        if (lp.contains(t)) s += 5;
        if (lp.split('/').last.contains(t)) s += 4;
      }
      if (lp.endsWith('.md') || lp.endsWith('readme')) s += 1;
      return s;
    }

    final candidates = nodes.where((n) => !n.isDir).map((n) => (n: n, s: score(n))).where((x) => x.s > 0).toList()
      ..sort((a, b) => b.s.compareTo(a.s));

    buf.writeln('\nRELEVANT FILES (content below):');
    var used = buf.length;
    var included = 0;
    for (final c in candidates) {
      if (included >= 8) break;
      final content = projects.readFile(c.n.path);
      if (content == null) continue;
      final clipped = content.length > 4000 ? '${content.substring(0, 4000)}\n… (truncated)' : content;
      final block = '\n--- FILE: ${c.n.path} ---\n$clipped\n';
      if (used + block.length > maxChars) break;
      buf.write(block);
      used += block.length;
      included++;
    }
    if (included == 0) buf.writeln('(no files matched the request keywords — ask the user or use search)');
    buf.writeln('\nUSER REQUEST: $request');
    buf.writeln('CURRENT DATE: 2026-09-17');
    return buf.toString();
  }

  static const systemPrompt = '''You are CodePilot, a coding agent working on the user's project.
You receive PROJECT context (structure + relevant files) and the user's request.
Rules:
- Answer with a short explanation first, then, when code changes are needed, output changes in this exact block format so the app can apply them:
```codepilot:write path/to/file.dart
<complete new file content>
```
```codepilot:delete path/to/file
```
- Write COMPLETE file contents (not snippets) for write blocks.
- Never invent file contents you have not seen; use the provided context only.
- Never include API keys or secrets in code.
- Keep explanations concise.''';

  /// Parse the model reply into text + proposed changes.
  static ({String explanation, List<ProposedChange> changes}) parseReply(String reply) {
    final changes = <ProposedChange>[];
    final explanation = StringBuffer();
    final writeRe = RegExp(r'```codepilot:write\s+(\S+)\n([\s\S]*?)```', multiLine: true);
    final deleteRe = RegExp(r'```codepilot:delete\s+(\S+)\s*```', multiLine: true);
    var consumed = reply;

    for (final m in writeRe.allMatches(reply)) {
      changes.add(ProposedChange(
        kind: 'write', path: m.group(1)!, before: '', after: m.group(2) ?? '',
        diff: const [], isNew: true,
      ));
      consumed = consumed.replaceFirst(m.group(0)!, '');
    }
    for (final m in deleteRe.allMatches(consumed)) {
      changes.add(ProposedChange(
        kind: 'delete', path: m.group(1)!, before: '', after: '',
        diff: const [], isNew: false,
      ));
      consumed = consumed.replaceFirst(m.group(0)!, '');
    }
    explanation.write(consumed.replaceAll('```', '').trim());
    return (explanation: explanation.toString(), changes: changes);
  }
}

/// A pending file change awaiting user confirmation.
class ProposedChange {
  final String kind; // write | delete
  final String path;
  final String before;
  final String after;
  final List<DiffLine> diff;
  final bool isNew;

  const ProposedChange({
    required this.kind,
    required this.path,
    required this.before,
    required this.after,
    required this.diff,
    required this.isNew,
  });
}
