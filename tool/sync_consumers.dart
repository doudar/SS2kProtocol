import 'dart:io';

/// Copies the buildable subset of this library into a standalone checkout.
/// Paths are resolved from the protocol repository root.
void main(List<String> args) {
  final check = args.contains('--check');
  final paths = args.where((a) => a != '--check').toList();
  if (paths.length != 2 || !['app', 'firmware'].contains(paths[0])) {
    stderr.writeln(
        'Usage: dart tool/sync_consumers.dart <app|firmware> <consumer-root> [--check]');
    exitCode = 2;
    return;
  }
  final app = paths[0] == 'app';
  final root = Directory(paths[1]).absolute;
  if (!File('${root.path}/${app ? 'pubspec.yaml' : 'platformio.ini'}')
      .existsSync()) {
    throw ArgumentError('Expected a consumer repository at ${root.path}');
  }
  final names = app
      ? [
          'LICENSE',
          'pubspec.yaml',
          'lib/ss2k_protocol.dart',
          'lib/secure.dart',
          'lib/src/generated.dart'
        ]
      : [
          'LICENSE',
          'library.json',
          'c/include/CustomCharacteristicProtocol.h',
          'c/include/ss2k_protocol.h',
          'c/include/ss2k_protocol_generated.h',
          'c/include/ss2k_secure.h',
          'c/src/descriptors.inc',
          'c/src/ss2k_protocol.c'
        ];
  for (final name in names) {
    final data = File(name).readAsStringSync().replaceAll('\r\n', '\n');
    final dest = File(
        '${root.path}/${app ? 'packages/ss2k_protocol' : 'lib/SS2kProtocol'}/$name');
    if (dest.existsSync() &&
        dest.readAsStringSync().replaceAll('\r\n', '\n') == data) continue;
    if (check) {
      stderr.writeln('Stale: ${dest.path}');
      exitCode = 1;
    } else {
      dest.parent.createSync(recursive: true);
      dest.writeAsStringSync(data);
    }
  }
}
