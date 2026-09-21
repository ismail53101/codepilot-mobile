import 'package:flutter_test/flutter_test.dart';

import 'package:codepilot_mobile/github_service.dart';
import 'package:codepilot_mobile/models.dart';

void main() {
  group('githubRepoFromZipballLayout', () {
    test('recovers owner/repo from a real imported zipball folder', () {
      final repo = githubRepoFromZipballLayout(
          ['ismail53101-codepilot-mobile-12cea2d']);
      expect(repo, isNotNull);
      expect(repo!.owner, 'ismail53101');
      expect(repo.name, 'codepilot-mobile');
      expect(repo.fullName, 'ismail53101/codepilot-mobile');
    });

    test('repo names containing hyphens are reconstructed fully', () {
      final repo = githubRepoFromZipballLayout(['octocat-hello-world-1a2b3c4']);
      expect(repo!.owner, 'octocat');
      expect(repo.name, 'hello-world');
    });

    test('a plain project folder (ZIP import / created) is NOT a repo', () {
      expect(githubRepoFromZipballLayout(['codepilot-mobile']), isNull);
    });

    test('multiple root entries mean no zipball wrapper', () {
      expect(
        githubRepoFromZipballLayout(
            ['ismail53101-codepilot-mobile-12cea2d', 'README.md']),
        isNull,
      );
    });

    test('an empty project has no repository identity', () {
      expect(githubRepoFromZipballLayout([]), isNull);
    });

    test('last segment must look like a git sha', () {
      // "version" is not hex — not a zipball layout.
      expect(
        githubRepoFromZipballLayout(['myorg-myrepo-version']),
        isNull,
      );
      // A 40-char full sha parses.
      final repo = githubRepoFromZipballLayout(
          ['myorg-myrepo-${'a' * 40}']);
      expect(repo!.name, 'myrepo');
    });

    test('an honest non-owner single segment fails cleanly', () {
      expect(githubRepoFromZipballLayout(['just-one-folder']), isNull);
    });

    test('CodePilot marker files do not break recovery', () {
      // importZip writes hidden markers (.codepilot_project, manifest) at
      // the root; callers pass the VISIBLE entries only, but even if a
      // hidden entry slips through the single-visible-entry rule is what
      // matters — two visible entries must still be rejected.
      expect(
        githubRepoFromZipballLayout(
            ['ismail53101-codepilot-mobile-12cea2d', 'notes.txt']),
        isNull,
      );
    });
  });

  group('collapseDuplicateSystemErrors', () {
    test('collapses a run of identical GitHub-connection error cards', () {
      final err = ChatMessage(
        role: 'system',
        content:
            'Connect and import a GitHub repository first from Integrations → GitHub.',
        isError: true,
      );
      final restored = collapseDuplicateSystemErrors([err, err, err, err]);
      expect(restored, hasLength(1));
    });

    test('keeps distinct errors and non-error messages', () {
      final messages = [
        ChatMessage(role: 'user', content: 'task'),
        ChatMessage(role: 'system', content: 'Error A', isError: true),
        ChatMessage(role: 'system', content: 'Error A', isError: true),
        ChatMessage(role: 'system', content: 'Error B', isError: true),
        ChatMessage(role: 'system', content: 'info'),
        ChatMessage(role: 'system', content: 'info'),
      ];
      final out = collapseDuplicateSystemErrors(messages);
      expect(out, hasLength(5)); // user, Error A once, Error B, info, info
      expect(out[0].role, 'user');
      expect(out[1].content, 'Error A');
      expect(out[2].content, 'Error B');
      // Non-error duplicates are preserved (dedup applies to errors only).
      expect(out.where((m) => m.content == 'info'), hasLength(2));
    });

    test('keeps identical errors separated by other messages', () {
      final messages = [
        ChatMessage(role: 'system', content: 'Error A', isError: true),
        ChatMessage(role: 'user', content: 'retry'),
        ChatMessage(role: 'system', content: 'Error A', isError: true),
      ];
      // Only CONSECUTIVE duplicates collapse; each real occurrence stays.
      expect(collapseDuplicateSystemErrors(messages), hasLength(3));
    });

    test('empty transcript stays empty', () {
      expect(collapseDuplicateSystemErrors(const []), isEmpty);
    });
  });
}
