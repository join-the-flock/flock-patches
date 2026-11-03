import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

/// Validates Nest patch collections without fetching or modifying Flutter.
final class PatchValidator {
  PatchValidator({Map<String, String>? environment})
    : _environment = Map.of(environment ?? Platform.environment)
        ..removeWhere(
          (key, _) => const {
            'GIT_DIR',
            'GIT_WORK_TREE',
            'GIT_INDEX_FILE',
            'GIT_COMMON_DIR',
          }.contains(key.toUpperCase()),
        );

  final Map<String, String> _environment;

  // GitHub PR downloads may contain several format-patch messages.
  static final _envelope = RegExp(
    r'^From [0-9a-f]{40}(?:[0-9a-f]{24})? [^\r\n]+\r?$',
    multiLine: true,
  );

  static bool _safePath(String name) =>
      name.isNotEmpty &&
      name == name.trim() &&
      !name.contains(r'\') &&
      !p.posix.isAbsolute(name) &&
      p.windows.rootPrefix(name).isEmpty &&
      !p.posix.split(name).any((part) => part == '..' || part == '.git') &&
      p.posix.normalize(name) == name;

  Future<ProcessResult> _git(
    List<String> arguments,
    Directory directory, {
    List<int> input = const [],
    Map<String, String> environment = const {},
  }) async {
    final process = await Process.start(
      'git',
      arguments,
      workingDirectory: directory.path,
      environment: {..._environment, ...environment},
      includeParentEnvironment: false,
    );
    const decoder = Utf8Decoder(allowMalformed: true);
    final stdout = process.stdout.transform(decoder).join();
    final stderr = process.stderr.transform(decoder).join();
    process.stdin.add(input);
    final completion = Future.wait<Object?>([
      process.exitCode,
      stdout,
      stderr,
      process.stdin.close(),
    ]);
    try {
      final result = await completion.timeout(const Duration(seconds: 30));
      return ProcessResult(
        process.pid,
        result[0] as int,
        result[1] as String,
        result[2] as String,
      );
    } on TimeoutException {
      process.kill(ProcessSignal.sigkill);
      await process.exitCode;
      rethrow;
    }
  }

  Future<List<String>> _validatePatch(
    List<int> bytes,
    Directory directory,
  ) async {
    final String data;
    try {
      data = utf8.decode(bytes);
    } on FormatException {
      return ['patch files must be UTF-8 for Nest import'];
    }
    final envelopes = _envelope.allMatches(data).toList();
    if (envelopes.isEmpty || envelopes.first.start != 0) {
      return ['expected a Git format-patch mail envelope'];
    }

    final errors = <String>[];
    final boundaries = [...envelopes.map((match) => match.start), data.length];
    for (var index = 0; index < envelopes.length; index++) {
      final label = 'commit ${index + 1}';
      final mail = await _git(
        [
          'mailinfo',
          '-k',
          '--encoding=UTF-8',
          '--no-scissors',
          'message',
          'diff',
        ],
        directory,
        input: utf8.encode(
          data.substring(boundaries[index], boundaries[index + 1]),
        ),
      );
      if (mail.exitCode != 0) {
        errors.add('$label: invalid mail: ${(mail.stderr as String).trim()}');
        continue;
      }
      final metadata = <String, String>{};
      for (final line in const LineSplitter().convert(mail.stdout as String)) {
        final colon = line.indexOf(':');
        if (colon != -1) {
          metadata[line.substring(0, colon)] = line.substring(colon + 1).trim();
        }
      }
      for (final field in ['Author', 'Email', 'Date', 'Subject']) {
        if ((metadata[field] ?? '').isEmpty) {
          errors.add('$label: missing $field mail metadata');
        }
      }
      if (metadata['Email'] case final String email when email.isNotEmpty) {
        if (!email.contains('@')) {
          errors.add('$label: invalid author email');
        }
      }
      if (metadata['Date'] case final String date when date.isNotEmpty) {
        // Use Git's own date parser, as git am does. It accepts historical
        // weekday discrepancies without rewriting the patch's metadata.
        final result = await _git(
          ['var', 'GIT_AUTHOR_IDENT'],
          directory,
          environment: {
            'GIT_AUTHOR_NAME': 'Patch validator',
            'GIT_AUTHOR_EMAIL': 'validator@example.com',
            'GIT_AUTHOR_DATE': date,
          },
        );
        if (result.exitCode != 0) {
          errors.add('$label: invalid author date');
        }
      }

      // Parse binary, rename, mode-only and text diffs without applying them.
      final diff = await _git(
        ['apply', '--numstat', '-z'],
        directory,
        input: File(p.join(directory.path, 'diff')).readAsBytesSync(),
      );
      final output = diff.stdout as String;
      if (diff.exitCode != 0) {
        errors.add('$label: invalid diff: ${(diff.stderr as String).trim()}');
      } else if (output.isEmpty) {
        errors.add('$label: contains no file changes');
      } else {
        for (final record
            in output.split('\x00').where((record) => record.isNotEmpty)) {
          final filename = record.substring(
            record.indexOf('\t', record.indexOf('\t') + 1) + 1,
          );
          if (!_safePath(filename)) {
            errors.add('$label: unsafe diff path ${jsonEncode(filename)}');
          }
        }
      }
    }
    return errors;
  }

  /// Returns all validation errors; the collection is never modified.
  Future<List<String>> validate(Directory collection) async {
    final Directory root;
    try {
      root = Directory(collection.resolveSymbolicLinksSync());
    } on FileSystemException catch (error) {
      return ['cannot read patch collection: $error'];
    }
    final manifest = File(p.join(root.path, '.patches'));
    if (FileSystemEntity.typeSync(manifest.path, followLinks: false) !=
        FileSystemEntityType.file) {
      return ['.patches must be a regular file'];
    }
    final List<String> entries;
    try {
      entries = const LineSplitter().convert(manifest.readAsStringSync());
    } on FileSystemException catch (error) {
      return ['cannot read .patches: $error'];
    } on FormatException catch (error) {
      return ['cannot read .patches: $error'];
    }
    if (entries.isEmpty) {
      return ['.patches must list at least one patch'];
    }

    final errors = <String>[];
    final listed = <String>{};
    final patches = <File>[];
    for (var index = 0; index < entries.length; index++) {
      final entry = entries[index];
      final label = '.patches:${index + 1}';
      if (!_safePath(entry) || !entry.endsWith('.patch')) {
        errors.add(
          '$label: expected a safe relative .patch filename, got ${jsonEncode(entry)}',
        );
        continue;
      }
      if (!listed.add(entry)) {
        errors.add('$label: duplicate entry ${jsonEncode(entry)}');
        continue;
      }
      var path = root.path;
      var hasSymlink = false;
      for (final part in p.posix.split(entry)) {
        path = p.join(path, part);
        if (FileSystemEntity.typeSync(path, followLinks: false) ==
            FileSystemEntityType.link) {
          errors.add(
            '$label: patch paths cannot contain symlinks: ${jsonEncode(entry)}',
          );
          hasSymlink = true;
          break;
        }
      }
      if (!hasSymlink) {
        if (FileSystemEntity.typeSync(path, followLinks: false) !=
            FileSystemEntityType.file) {
          errors.add('$label: missing patch ${jsonEncode(entry)}');
        } else {
          patches.add(File(path));
        }
      }
    }

    for (final entity in root.listSync(recursive: true, followLinks: false)) {
      final parts = p.split(p.relative(entity.path, from: root.path));
      final relative = parts.join('/');
      if (!parts.contains('.git') &&
          relative.endsWith('.patch') &&
          !listed.contains(relative)) {
        errors.add('$relative: patch is not listed in .patches');
      }
    }

    final temporary = Directory.systemTemp.createTempSync(
      'flock-patch-validation-',
    );
    try {
      for (final file in patches) {
        final name = p.split(p.relative(file.path, from: root.path)).join('/');
        try {
          errors.addAll(
            (await _validatePatch(
              file.readAsBytesSync(),
              temporary,
            )).map((error) => '$name: $error'),
          );
        } on FileSystemException catch (error) {
          errors.add('$name: validation failed: $error');
        } on ProcessException catch (error) {
          errors.add('$name: validation failed: $error');
        } on TimeoutException catch (error) {
          errors.add('$name: validation failed: $error');
        }
      }
    } finally {
      temporary.deleteSync(recursive: true);
    }
    return errors;
  }
}
