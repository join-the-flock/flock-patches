import 'dart:io';

import 'package:flock_patches_infra/patch_validation.dart';

Future<void> main(List<String> arguments) async {
  if (arguments.length > 1 ||
      arguments.any((argument) => argument.startsWith('-'))) {
    final help = arguments.length == 1 && arguments.single == '--help';
    (help ? stdout : stderr).writeln(
      'Usage: dart run tools/validate_patches.dart [repository]',
    );
    exitCode = help ? 0 : 64;
    return;
  }
  final root = arguments.isEmpty
      ? File.fromUri(Platform.script).parent.parent.parent
      : Directory(arguments.single);
  final errors = await PatchValidator().validate(root);
  if (errors.isEmpty) {
    stdout.writeln('Patch manifest, mail metadata, and diff syntax are valid.');
  } else {
    for (final error in errors) {
      stderr.writeln(error);
    }
    stderr.writeln('Patch validation failed: ${errors.length} error(s).');
    exitCode = 1;
  }
}
