import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as path;
import 'package:test/test.dart';

void main() {
  group('Patch collection validation >', () {
    late Directory root;
    late File manifest;
    late File patch;

    setUp(() {
      root = Directory.systemTemp.createTempSync('flock-patch-tests-');
      manifest = File(path.join(root.path, '.patches-master'))
        ..writeAsStringSync('example.patch');
      for (final channel in ['beta', 'stable']) {
        File(path.join(root.path, '.patches-$channel'))
            .writeAsStringSync('example.patch');
      }
      patch = File(path.join(root.path, 'example.patch'))
        ..writeAsStringSync(_validPatch);
    });

    tearDown(() => root.deleteSync(recursive: true));

    group('Collection files >', () {
      test(
        'preserves collection file names and contents when validation succeeds',
        () async {
          final before = {
            for (final file in root.listSync().whereType<File>())
              file.path: file.readAsBytesSync(),
          };
          await _expectValidationSuccess(root);
          expect({
            for (final file in root.listSync().whereType<File>())
              file.path: file.readAsBytesSync(),
          }, before);
        },
      );
    });

    group('Channel manifests >', () {
      test('rejects patch files in subdirectories', () async {
        final nested = Directory(path.join(root.path, 'nested'))..createSync();
        File(path.join(nested.path, 'example.patch'))
            .writeAsStringSync(_validPatch);
        manifest.writeAsStringSync('nested/example.patch\n');
        await _expectValidationFailure(
          root,
          'must live in the repository root',
        );
      });

      test('requires a manifest for every channel', () async {
        for (final channel in ['master', 'beta', 'stable']) {
          final selected = File(path.join(root.path, '.patches-$channel'));
          selected.deleteSync();
          await _expectValidationFailure(
            root,
            '.patches-$channel must be a regular file',
          );
          selected.writeAsStringSync('example.patch');
        }
      });

      test('rejects the legacy manifest beside channel manifests', () async {
        File(path.join(root.path, '.patches'))
            .writeAsStringSync('example.patch');
        await _expectValidationFailure(root, 'replace .patches');
      });

      test('rejects a missing, empty, or non-UTF-8 manifest', () async {
        manifest.deleteSync();
        await _expectValidationFailure(
          root,
          '.patches-master must be a regular file',
        );
        manifest.writeAsStringSync('');
        await _expectValidationFailure(root, 'must list at least one patch');
        manifest.writeAsBytesSync([255]);
        await _expectValidationFailure(root, 'cannot read .patches-master');
      });

      test(
        'rejects blank or duplicate entries and references to missing files',
        () async {
          for (final (contents, expected) in [
            ('example.patch\n\n', 'safe relative'),
            ('example.patch\nexample.patch\n', 'duplicate entry'),
            ('missing.patch\n', 'missing patch'),
          ]) {
            manifest.writeAsStringSync(contents);
            await _expectValidationFailure(root, expected);
          }
        },
      );

      test('ignores patches inside Git metadata and rejects unlisted collection patches', () async {
        final metadata = Directory(path.join(root.path, '.git'))..createSync();
        File(path.join(metadata.path, 'internal.patch'))
            .writeAsStringSync('not a collection entry');
        await _expectValidationSuccess(root);
        File(path.join(root.path, 'unlisted.patch'))
            .writeAsStringSync(_validPatch);
        await _expectValidationFailure(
          root,
          'unlisted.patch: patch is not listed',
        );
      });

      test('rejects absolute, parent-relative, noncanonical, and Git metadata paths', () async {
        for (final name in [
          '../outside.patch',
          '/outside.patch',
          './example.patch',
          'nested/../example.patch',
          r'nested\example.patch',
          '.git/internal.patch',
          'C:/outside.patch',
        ]) {
          manifest.writeAsStringSync(name);
          await _expectValidationFailure(root, 'safe relative');
        }
      });

      test(
        'rejects symbolic link manifests and patches, and directory entries',
        () async {
          patch.deleteSync();
          Link(patch.path)
              .createSync(path.join(root.parent.path, 'outside.patch'));
          await _expectValidationFailure(root, 'cannot contain symlinks');
          Link(patch.path).deleteSync();
          patch.writeAsStringSync(_validPatch);
          Link(path.join(root.path, 'linked')).createSync(root.path);
          manifest.writeAsStringSync('linked/example.patch');
          await _expectValidationFailure(
            root,
            'must live in the repository root',
          );
          manifest.deleteSync();
          Link(manifest.path).createSync(patch.path);
          await _expectValidationFailure(
            root,
            '.patches-master must be a regular file',
          );
        },
      );
    });

    group('Patch variants >', () {
      test(
        'accepts a shared baseline and channel-specific dated adaptations',
        () async {
          for (final (channel, name) in [
            ('master', 'example_2026-09-08.patch'),
            ('beta', 'example_2026-05-01.patch'),
          ]) {
            File(path.join(root.path, name)).writeAsStringSync(_validPatch);
            File(path.join(root.path, '.patches-$channel'))
                .writeAsStringSync(name);
          }
          await _expectValidationSuccess(root);
        },
      );

      test('accepts patches selected by only one channel', () async {
        final extra = File(path.join(root.path, 'master_only.patch'))
          ..writeAsStringSync(_validPatch);
        manifest.writeAsStringSync(
          'example.patch\n${path.basename(extra.path)}',
        );
        await _expectValidationSuccess(root);
      });

      test('rejects a baseline and an adaptation of the same change in one channel', () async {
        File(path.join(root.path, 'example_2026-09-08.patch'))
            .writeAsStringSync(_validPatch);
        manifest.writeAsStringSync('example.patch\nexample_2026-09-08.patch');
        await _expectValidationFailure(
          root,
          '.patches-master:2: multiple variants of example',
        );
      });

      test(
        'rejects two dated adaptations of the same change in one channel',
        () async {
          for (final date in ['2026-05-01', '2026-09-08']) {
            File(path.join(root.path, 'example_$date.patch'))
                .writeAsStringSync(_validPatch);
          }
          manifest.writeAsStringSync(
            'example_2026-05-01.patch\nexample_2026-09-08.patch',
          );
          await _expectValidationFailure(root, 'multiple variants of example');
        },
      );

      test(
        'accepts leap-day dates and rejects impossible adaptation dates',
        () async {
          for (final (date, valid) in [
            ('2024-02-29', true),
            ('2026-02-29', false),
            ('2026-13-01', false),
            ('2026-04-31', false),
            ('2026-9-8', false),
          ]) {
            final adaptation = File(path.join(root.path, 'example_$date.patch'))
              ..writeAsStringSync(_validPatch);
            manifest.writeAsStringSync(path.basename(adaptation.path));
            if (valid) {
              await _expectValidationSuccess(root);
            } else {
              await _expectValidationFailure(
                root,
                'invalid adaptation date $date',
              );
            }
            adaptation.deleteSync();
          }
        },
      );

      test('validates a patch selected by only beta', () async {
        File(path.join(root.path, 'beta_only.patch'))
            .writeAsStringSync('invalid mail');
        File(path.join(root.path, '.patches-beta'))
            .writeAsStringSync('example.patch\nbeta_only.patch');
        await _expectValidationFailure(
          root,
          'beta_only.patch: expected a Git format-patch mail envelope',
        );
      });

      test(
        'accepts a dated adaptation after its baseline is retired',
        () async {
          patch.renameSync(path.join(root.path, 'example_2026-09-08.patch'));
          for (final channel in ['master', 'beta', 'stable']) {
            File(path.join(root.path, '.patches-$channel'))
                .writeAsStringSync('example_2026-09-08.patch');
          }
          await _expectValidationSuccess(root);
        },
      );

      test('reports an invalid shared patch once', () async {
        patch.writeAsStringSync('invalid mail');
        final result = await _runValidator(root);
        expect(result.exitCode, 1);
        expect(
          'expected a Git format-patch mail envelope'.allMatches(
            result.stderr as String,
          ),
          hasLength(1),
        );
      });

      test('reports errors in multiple channel manifests together', () async {
        manifest.writeAsStringSync('missing_master.patch');
        File(path.join(root.path, '.patches-beta'))
            .writeAsStringSync('missing_beta.patch');
        final result = await _runValidator(root);
        expect(result.exitCode, 1);
        expect(result.stderr, contains('.patches-master:1: missing patch'));
        expect(result.stderr, contains('.patches-beta:1: missing patch'));
      });
    });

    group('Patch file format >', () {
      test('accepts two valid commits and reports an invalid diff in the second commit', () async {
        patch.writeAsStringSync('$_validPatch\n$_validPatch');
        await _expectValidationSuccess(root);
        final broken = _patchMail + _patchDiff.replaceFirst('+1 @@', '+1,2 @@');
        patch.writeAsStringSync('$_validPatch\n$broken');
        await _expectValidationFailure(root, 'commit 2: invalid diff');
      });

      test('accepts a nonzero envelope commit identifier and a mismatched date weekday', () async {
        patch.writeAsStringSync(
          _validPatch
              .replaceFirst(
                '0000000000000000000000000000000000000000',
                'a' * 40,
              )
              .replaceFirst('Tue, 3 Nov', 'Sun, 3 Nov'),
        );
        await _expectValidationSuccess(root);
      });

      test('accepts patch files with Windows line endings', () async {
        patch.writeAsStringSync(_validPatch.replaceAll('\n', '\r\n'));
        await _expectValidationSuccess(root);
      });

      test('rejects patch files containing invalid UTF-8 bytes', () async {
        patch.writeAsBytesSync([...utf8.encode(_patchMail + _patchDiff), 255]);
        await _expectValidationFailure(root, 'patch files must be UTF-8');
      });

      test(
        'rejects patch mail with a missing author, date, or subject',
        () async {
          for (final (header, expected) in [
            ('From: Example Author <author@example.com>\n', 'missing Author'),
            ('Date: Tue, 3 Nov 2026 12:00:00 +0000\n', 'missing Date'),
            ('Subject: [PATCH] Add an example\n', 'missing Subject'),
          ]) {
            patch.writeAsStringSync(_validPatch.replaceFirst(header, ''));
            await _expectValidationFailure(root, expected);
          }
        },
      );

      test(
        'rejects an invalid author date or an author email without an at sign',
        () async {
          patch.writeAsStringSync(
            _validPatch.replaceFirst(
              'Tue, 3 Nov 2026 12:00:00 +0000',
              'not a date',
            ),
          );
          await _expectValidationFailure(root, 'invalid author date');
          patch.writeAsStringSync(
            _validPatch.replaceFirst('author@example.com', 'invalid-email'),
          );
          await _expectValidationFailure(root, 'invalid author email');
        },
      );

      test('rejects a missing mail envelope, a missing diff, or an incomplete hunk', () async {
        for (final (data, expected) in [
          (_patchDiff, 'mail envelope'),
          (_patchMail, 'invalid diff'),
          (
            _patchMail + _patchDiff.replaceFirst('+1 @@', '+1,2 @@'),
            'invalid diff',
          ),
        ]) {
          patch.writeAsStringSync(data);
          await _expectValidationFailure(root, expected);
        }
      });
    });

    group('Git diffs >', () {
      test('rejects diff paths that traverse a parent directory', () async {
        patch.writeAsStringSync(
          _patchMail + _patchDiff.replaceAll('example.txt', '../outside.txt'),
        );
        await _expectValidationFailure(root, 'unsafe diff path');
      });

      test('accepts permission-only and rename-only diffs', () async {
        for (final changes in [
          'diff --git a/example.txt b/example.txt\nold mode 100644\nnew mode 100755\n',
          'diff --git a/old.txt b/new.txt\nsimilarity index 100%\nrename from old.txt\nrename to new.txt\n',
        ]) {
          patch.writeAsStringSync(_patchMail + changes);
          await _expectValidationSuccess(root);
        }
      });

      test('accepts a Git binary diff', () async {
        final binary = File(path.join(root.path, 'example.bin'))
          ..writeAsBytesSync(List.generate(256, (index) => index));
        final result = await Process.run('git', [
          'diff',
          '--no-index',
          '--binary',
          '--',
          '/dev/null',
          'example.bin',
        ], workingDirectory: root.path);
        expect(result.exitCode, 1);
        binary.deleteSync();
        patch.writeAsStringSync(_patchMail + (result.stdout as String));
        await _expectValidationSuccess(root);
      });
    });

    group('Command execution >', () {
      test(
        'accepts a valid collection despite invalid inherited Git paths',
        () async {
          await _expectValidationSuccess(
            root,
            environment: {
              'GIT_DIR': '/nonexistent',
              'GIT_WORK_TREE': '/nonexistent',
            },
          );
        },
      );

      test(
        'reports a missing listed patch on stderr and exits with code 1',
        () async {
          manifest.writeAsStringSync('missing.patch');
          final result = await Process.run(Platform.resolvedExecutable, [
            'run',
            'bin/validate.dart',
            root.path,
          ]);
          expect(result.exitCode, 1);
          expect(result.stderr, contains('missing.patch'));
        },
      );
    });
  });
}

Future<void> _expectValidationSuccess(
  Directory root, {
  Map<String, String> environment = const {},
}) async {
  final result = await _runValidator(root, environment: environment);
  expect(result.exitCode, 0, reason: result.stderr as String);
  expect(
    result.stdout,
    contains(
      'Channel manifests, patch variants, mail metadata, and diff syntax are valid.',
    ),
  );
}

Future<void> _expectValidationFailure(Directory root, String message) async {
  final result = await _runValidator(root);
  expect(result.exitCode, 1);
  expect(result.stderr, contains(message));
}

Future<ProcessResult> _runValidator(
  Directory root, {
  Map<String, String> environment = const {},
}) {
  return Process.run(Platform.resolvedExecutable, [
    '--packages=${path.absolute('.dart_tool', 'package_config.json')}',
    path.absolute('bin', 'validate.dart'),
    root.path,
  ], environment: environment);
}

const _validPatch = _patchMail + _patchDiff;

const _patchMail =
    'From 0000000000000000000000000000000000000000 Mon Sep 17 00:00:00 2001\n'
    'From: Example Author <author@example.com>\n'
    'Date: Tue, 3 Nov 2026 12:00:00 +0000\n'
    'Subject: [PATCH] Add an example\n\n';
const _patchDiff =
    'diff --git a/example.txt b/example.txt\n'
    'new file mode 100644\n'
    'index 0000000..ce01362\n'
    '--- /dev/null\n'
    '+++ b/example.txt\n'
    '@@ -0,0 +1 @@\n'
    '+hello\n';
