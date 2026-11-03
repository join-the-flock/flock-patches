import 'dart:convert';
import 'dart:io';

import 'package:flock_patches_infra/patch_validation.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

const mail =
    'From 0000000000000000000000000000000000000000 Mon Sep 17 00:00:00 2001\n'
    'From: Example Author <author@example.com>\n'
    'Date: Tue, 3 Nov 2026 12:00:00 +0000\n'
    'Subject: [PATCH] Add an example\n\n';
const diff =
    'diff --git a/example.txt b/example.txt\n'
    'new file mode 100644\n'
    'index 0000000..ce01362\n'
    '--- /dev/null\n'
    '+++ b/example.txt\n'
    '@@ -0,0 +1 @@\n'
    '+hello\n';
const validPatch = mail + diff;

void main() {
  late Directory root;
  late File manifest;
  late File patch;
  late PatchValidator validator;

  Future<void> expectInvalid(String expected) async {
    expect(await validator.validate(root), anyElement(contains(expected)));
  }

  setUp(() {
    root = Directory.systemTemp.createTempSync('flock-patch-tests-');
    manifest = File(p.join(root.path, '.patches'))
      ..writeAsStringSync('example.patch');
    patch = File(p.join(root.path, 'example.patch'))
      ..writeAsStringSync(validPatch);
    validator = PatchValidator();
  });

  tearDown(() => root.deleteSync(recursive: true));

  test(
    'validates without Flutter and does not modify the collection',
    () async {
      final before = {
        for (final file in root.listSync().whereType<File>())
          file.path: file.readAsBytesSync(),
      };
      expect(await validator.validate(root), isEmpty);
      expect({
        for (final file in root.listSync().whereType<File>())
          file.path: file.readAsBytesSync(),
      }, before);
    },
  );

  test('checks every commit in a multi-commit patch', () async {
    patch.writeAsStringSync('$validPatch\n$validPatch');
    expect(await validator.validate(root), isEmpty);
    final broken = mail + diff.replaceFirst('+1 @@', '+1,2 @@');
    patch.writeAsStringSync('$validPatch\n$broken');
    await expectInvalid('commit 2: invalid diff');
  });

  test(
    'accepts nonzero commit IDs and historical weekday discrepancies',
    () async {
      patch.writeAsStringSync(
        validPatch
            .replaceFirst('0000000000000000000000000000000000000000', 'a' * 40)
            .replaceFirst('Tue, 3 Nov', 'Sun, 3 Nov'),
      );
      expect(await validator.validate(root), isEmpty);
    },
  );

  test('accepts CRLF mail', () async {
    patch.writeAsStringSync(validPatch.replaceAll('\n', '\r\n'));
    expect(await validator.validate(root), isEmpty);
  });

  test('supports nested patch files', () async {
    final nested = Directory(p.join(root.path, 'nested'))..createSync();
    patch.renameSync(p.join(nested.path, 'example.patch'));
    manifest.writeAsStringSync('nested/example.patch\n');
    expect(await validator.validate(root), isEmpty);
  });

  test('rejects missing, empty and invalid UTF-8 manifests', () async {
    manifest.deleteSync();
    await expectInvalid('.patches must be a regular file');
    manifest.writeAsStringSync('');
    await expectInvalid('must list at least one patch');
    manifest.writeAsBytesSync([255]);
    await expectInvalid('cannot read .patches');
  });

  test('rejects blank, duplicate and missing manifest entries', () async {
    for (final (contents, expected) in [
      ('example.patch\n\n', 'safe relative'),
      ('example.patch\nexample.patch\n', 'duplicate entry'),
      ('missing.patch\n', 'missing patch'),
    ]) {
      manifest.writeAsStringSync(contents);
      await expectInvalid(expected);
    }
  });

  test('rejects unlisted patches and excludes Git metadata', () async {
    final metadata = Directory(p.join(root.path, '.git'))..createSync();
    File(p.join(metadata.path, 'internal.patch'))
        .writeAsStringSync('not a collection entry');
    expect(await validator.validate(root), isEmpty);
    File(p.join(root.path, 'unlisted.patch')).writeAsStringSync(validPatch);
    await expectInvalid('unlisted.patch: patch is not listed');
  });

  test('rejects unsafe manifest paths', () async {
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
      await expectInvalid('safe relative');
    }
  });

  test('rejects symlink manifests, patches and parent directories', () async {
    patch.deleteSync();
    Link(patch.path).createSync(p.join(root.parent.path, 'outside.patch'));
    await expectInvalid('cannot contain symlinks');
    Link(patch.path).deleteSync();
    patch.writeAsStringSync(validPatch);
    Link(p.join(root.path, 'linked')).createSync(root.path);
    manifest.writeAsStringSync('linked/example.patch');
    await expectInvalid('cannot contain symlinks');
    manifest.deleteSync();
    Link(manifest.path).createSync(patch.path);
    await expectInvalid('.patches must be a regular file');
  });

  test('requires UTF-8 patch files for Nest import', () async {
    patch.writeAsBytesSync([...utf8.encode(mail + diff), 255]);
    await expectInvalid('patch files must be UTF-8');
  });

  test('rejects missing author, date and subject metadata', () async {
    for (final (header, expected) in [
      ('From: Example Author <author@example.com>\n', 'missing Author'),
      ('Date: Tue, 3 Nov 2026 12:00:00 +0000\n', 'missing Date'),
      ('Subject: [PATCH] Add an example\n', 'missing Subject'),
    ]) {
      patch.writeAsStringSync(validPatch.replaceFirst(header, ''));
      await expectInvalid(expected);
    }
  });

  test('rejects invalid dates and email addresses', () async {
    patch.writeAsStringSync(
      validPatch.replaceFirst('Tue, 3 Nov 2026 12:00:00 +0000', 'not a date'),
    );
    await expectInvalid('invalid author date');
    patch.writeAsStringSync(
      validPatch.replaceFirst('author@example.com', 'invalid-email'),
    );
    await expectInvalid('invalid author email');
  });

  test(
    'rejects missing envelopes, empty diffs and invalid hunk counts',
    () async {
      for (final (data, expected) in [
        (diff, 'mail envelope'),
        (mail, 'invalid diff'),
        (mail + diff.replaceFirst('+1 @@', '+1,2 @@'), 'invalid diff'),
      ]) {
        patch.writeAsStringSync(data);
        await expectInvalid(expected);
      }
    },
  );

  test('rejects unsafe diff paths', () async {
    patch.writeAsStringSync(
      mail + diff.replaceAll('example.txt', '../outside.txt'),
    );
    await expectInvalid('unsafe diff path');
  });

  test('supports mode-only and rename patches', () async {
    for (final changes in [
      'diff --git a/example.txt b/example.txt\nold mode 100644\nnew mode 100755\n',
      'diff --git a/old.txt b/new.txt\nsimilarity index 100%\nrename from old.txt\nrename to new.txt\n',
    ]) {
      patch.writeAsStringSync(mail + changes);
      expect(await validator.validate(root), isEmpty);
    }
  });

  test('supports binary patches', () async {
    final binary = File(p.join(root.path, 'example.bin'))
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
    patch.writeAsStringSync(mail + (result.stdout as String));
    expect(await validator.validate(root), isEmpty);
  });

  test('ignores inherited Git checkout context', () async {
    final validator = PatchValidator(
      environment: {
        ...Platform.environment,
        'GIT_DIR': '/nonexistent',
        'GIT_WORK_TREE': '/nonexistent',
      },
    );
    expect(await validator.validate(root), isEmpty);
  });

  test('CLI exits unsuccessfully for an invalid collection', () async {
    manifest.writeAsStringSync('missing.patch');
    final result = await Process.run(Platform.resolvedExecutable, [
      'run',
      'tools/validate_patches.dart',
      root.path,
    ]);
    expect(result.exitCode, 1);
    expect(result.stderr, contains('missing.patch'));
  });
}
