import 'dart:convert';
import 'dart:io';
import '../lib/ss2k_protocol.dart' as p;
import '../tool/generate.dart' as g;
import '../tool/check_compatibility.dart' as compatibility;

void check(bool condition, String message) {
  if (!condition) throw StateError(message);
}

void rejects(void Function() action, String name) {
  try {
    action();
  } catch (_) {
    return;
  }
  throw StateError('Expected rejection: $name');
}

List<int> hex(String value) => value
    .split(RegExp(r'\s+'))
    .where((s) => s.isNotEmpty)
    .map((s) => int.parse(s, radix: 16))
    .toList();
String hexString(List<int> bytes) =>
    bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
ProcessResult run(String exe, List<String> args) {
  final result = Process.runSync(exe, args);
  if (result.exitCode != 0)
    throw StateError(
      '$exe failed (${result.exitCode}):\n${result.stdout}\n${result.stderr}',
    );
  return result;
}

void main() {
  Directory('build').createSync();
  final suffix = Platform.isWindows ? '.exe' : '';
  final cExe = File('build/test_c$suffix').absolute.path;
  final cppExe = File('build/test_cpp$suffix').absolute.path;
  run(Platform.environment['CC'] ?? 'gcc', [
    '-std=c99',
    '-O2',
    '-Wall',
    '-Wextra',
    '-Werror',
    '-pedantic',
    '-I',
    'c/include',
    'c/src/ss2k_protocol.c',
    'test/test_c.c',
    '-o',
    cExe,
  ]);
  stdout.write(run(cExe, []).stdout);
  run(Platform.environment['CXX'] ?? 'g++', [
    '-std=c++11',
    '-Wall',
    '-Wextra',
    '-Werror',
    '-pedantic',
    '-I',
    'c/include',
    'test/test_cpp.cpp',
    '-o',
    cppExe,
  ]);
  run(cppExe, []);
  final vectors =
      jsonDecode(File('test/vectors.json').readAsStringSync()) as List;
  final row = [
    2,
    0x27,
    9,
    for (var i = 0; i < p.power_table_columns; i++) ...[0, 0x80],
  ];
  vectors.addAll([
    {
      'name': 'full row write',
      'kind': 'request',
      'hex': hexString(row).replaceAllMapped(RegExp('..'), (m) => '${m[0]} '),
      'valid': true,
    },
    {
      'name': 'full row reply',
      'kind': 'read',
      'hex': hexString([
        0x80,
        ...row.sublist(1),
      ]).replaceAllMapped(RegExp('..'), (m) => '${m[0]} '),
      'valid': true,
    },
    {
      'name': 'short row',
      'kind': 'request',
      'hex': hexString(
        row.sublist(0, row.length - 1),
      ).replaceAllMapped(RegExp('..'), (m) => '${m[0]} '),
      'valid': false,
    },
  ]);
  for (final v in vectors) {
    final bytes = hex(v['hex']);
    var valid = true;
    p.ProtocolPacket? packet;
    try {
      if (v['kind'] == 'request') {
        p.validateRequest(bytes);
        check(
          hexString(p.encodeRequest(bytes[0], bytes[1], bytes.sublist(2))) ==
              hexString(bytes),
          'Dart request roundtrip',
        );
      } else {
        final kind = p.ReplyKind.values.byName(v['kind']);
        packet = p.decodeResponse(bytes, kind: kind);
      }
    } on FormatException {
      valid = false;
    } on ArgumentError {
      valid = false;
    } on UnsupportedError {
      valid = false;
    }
    check(valid == v['valid'], 'Dart vector ${v['name']}');
    final c = run(cExe, [v['kind'], hexString(bytes)]).stdout.toString().trim();
    final expected = v['valid']
        ? 'valid${v['error'] == true ? ' error' : v.containsKey('raw') ? ' ${v['raw']}' : ''}'
        : 'invalid';
    check(c == expected, 'C vector ${v['name']}: expected $expected got $c');
    if (v.containsKey('raw'))
      check(packet!.rawValue == v['raw'], 'Dart raw ${v['name']}');
    if (v['error'] == true) check(packet!.isError, 'Remote error lost');
  }
  check(
    hexString(p.encodeValue(p.CommandId.simulatedSpeed, 26.3)) == '02060701',
    'Speed engineering scale',
  );
  check(
    hexString(p.encodeValue(p.CommandId.incline, -5.5)) == '0202c9ff',
    'Signed engineering scale',
  );
  check(
    hexString(p.encodeValue(p.CommandId.deviceName, 'Café')) ==
        '0207436166c3a9',
    'UTF8',
  );
  check(
    hexString(p.encodeValue(p.CommandId.stealthChop, true)) == '020a01',
    'Bool canonical encoding',
  );
  check(
    hexString(p.encodeAction(p.CommandId.saveToLittleFS)) == '0218',
    'Action',
  );
  check(
    hexString(p.encodeGearTeeth([5319, 5332])) == '023402c714d414',
    'Gear pairs',
  );
  check(
    p.encodePowerTableRow(9, List.filled(30, -32768)).length == 63,
    'Power row width',
  );
  for (final c in p.commands.values) {
    final bounds = switch (c.writeRequest) {
      p.WireFormat.bool => <int>[0, 1],
      p.WireFormat.u16 => <int>[0, 65535],
      p.WireFormat.i16 => <int>[-32768, 32767],
      p.WireFormat.i32 => <int>[-2147483648, 2147483647],
      _ => <int>[],
    };
    for (final value in bounds) {
      final write = p.encodeScalarWrite(c.id, value)..[0] = p.success;
      check(
        p.decodeResponse(write, kind: p.ReplyKind.write).rawValue == value,
        'Scalar boundary ${c.name}',
      );
    }
    if (bounds.isNotEmpty) {
      rejects(
        () => p.encodeScalarWrite(c.id, bounds.first - 1),
        'Scalar underflow',
      );
      rejects(
        () => p.encodeScalarWrite(c.id, bounds.last + 1),
        'Scalar overflow',
      );
    }
  }
  rejects(() => p.encodeValue(p.CommandId.simulatedSpeed, double.nan), 'NaN');
  rejects(
    () => p.encodeValue(p.CommandId.simulatedSpeed, double.infinity),
    'infinite',
  );
  rejects(() => p.encodeRead(0x33), 'reserved');
  rejects(() => p.encodeRequest(2, 7, [256]), 'byte overflow');
  rejects(
    () => p.decodeResponse([-1, 7], kind: p.ReplyKind.read),
    'negative byte',
  );
  check(
    p.decodeResponse(
          [128, 10, 1, 0],
          kind: p.ReplyKind.write,
          legacyBooleanEcho: true,
        ).rawValue ==
        1,
    'Legacy bool echo',
  );
  final settings = p.createAppDescriptors();
  final settingsById = {for (final item in settings) item['reference']: item};
  check(
      settingsById['0x01']?['isSetting'] == false &&
          settingsById['0x11']?['defaultData'] == 'true',
      'Legacy update controls');
  check(
      settingsById['0x2E']?['settingsSnapshotKey'] == 'udpLogEnabled' &&
          settingsById['0x2E']?['showDescriptionInList'] == true,
      'UDP logging disclosure and snapshot alias');
  check(
      settingsById['0x13']?['defaultData'] == '', 'WiFi password starts empty');
  final second = p.createAppDescriptors();
  settings.first['defaultData'] = 'changed';
  check(second.first['defaultData'] != 'changed', 'App state isolation');
  check(
    settings.map((c) => c['reference']).toSet().length == settings.length,
    'Duplicate app references',
  );
  final snapshot = p.snapshotValues({
    'shifterDir': true,
    'udpLogEnabled': false,
    'hMin': -100000,
    'ignored': 42,
  });
  check(
    snapshot[p.CommandId.shiftDir] == true &&
        snapshot[p.CommandId.UDPLogging] == false &&
        snapshot[p.CommandId.hMin] == -100000,
    'Snapshot aliases',
  );

  final assembler = p.SnapshotAssembler();
  final payload = utf8.encode('{"deviceName":"Café"}');
  final split = payload.indexOf(0xc3) + 1; // Split a multibyte UTF8 character.
  final chunk0 = [128, 49, 1, 0, 0, 2, 0, ...payload.sublist(0, split)];
  final chunk1 = [128, 49, 1, 1, 0, 2, 0, ...payload.sublist(split)];
  check(assembler.add(chunk1) == null, 'Out of order pending');
  check(assembler.add(chunk1) == null, 'Identical duplicate');
  check(assembler.add(chunk0)?['deviceName'] == 'Café', 'UTF8 assembly');
  assembler.add(chunk0);
  rejects(() => assembler.add([...chunk0]..[7] = 0), 'Conflicting duplicate');
  check(
    assembler.add([128, 49, 1, 0, 0, 1, 0, 123, 125])!.isEmpty,
    'Reset after error',
  );
  rejects(
    () => p.SnapshotAssembler(
      maxBytes: 1,
    ).add([128, 49, 1, 0, 0, 1, 0, 123, 125]),
    'Byte cap',
  );
  rejects(() => p.SnapshotAssembler(maxChunks: 1).add(chunk0), 'Chunk cap');
  rejects(
    () => assembler.add([128, 49, 1, 0, 0, 1, 0, 91, 93]),
    'Snapshot array',
  );
  rejects(
    () => assembler.add([128, 49, 1, 0, 0, 1, 0, 0xff]),
    'Snapshot invalid UTF8',
  );
  final scan = p.ScanFragment([
    128,
    50,
    1,
    1,
    2,
    0,
    3,
    0,
    0,
    1,
    4,
    49,
    56,
    49,
    56,
    65,
  ]);
  check(
    scan.scanId == 2 && scan.sequence == 3 && scan.count == 1,
    'Scan header',
  );
  check(
    p.ScanFragment.decodeDeviceBody(scan.body) == (uuid: '1818', name: 'A'),
    'Scan body',
  );
  rejects(() => p.ScanFragment.decodeDeviceBody([4, 1]), 'Short UUID');

  final spec = jsonDecode(File('protocol/ss2k.json').readAsStringSync())
      as Map<String, dynamic>;
  Map<String, dynamic> clone() =>
      jsonDecode(jsonEncode(spec)) as Map<String, dynamic>;
  g.validate(spec);
  for (final edit in <void Function(Map<String, dynamic>)>[
    (s) => s['commands'][1]['id'] = s['commands'][0]['id'],
    (s) => s['commands'][0]['id'] = 51,
    (s) => s['commands'][0]['scale'] = 0,
    (s) => s['commands'][0]['read_response'] = 'uint17',
    (s) => s['commands'][0]['typo'] = true,
    (s) => s['commands'][0]['sensitive'] = 'no',
    (s) => s['commands'][0]['read_response'] = null,
    (s) => s['constants']['snapshot_header_length'] = 8,
  ]) {
    final changed = clone();
    edit(changed);
    rejects(() => g.validate(changed), 'Invalid schema');
  }
  final changed = clone();
  changed['commands'][0]['scale'] = 2;
  check(
    compatibility.compatibilityIssues(spec, changed).isNotEmpty,
    'Breaking scale detected',
  );
  final added = clone();
  final newCommand = Map<String, dynamic>.from(added['commands'][2]);
  newCommand.addAll({
    'id': 57,
    'name': 'exampleNewCommand',
    'legacy_name': 'BLE_exampleNewCommand',
    'app': null,
  });
  added['commands'].add(newCommand);
  final generated = g.render(added);
  check(
    generated['c/include/ss2k_protocol_generated.h']!.contains(
      'SS2K_ID_EXAMPLE_NEW_COMMAND',
    ),
    'New C ID from JSON',
  );
  check(
    generated['lib/src/generated.dart']!.contains('exampleNewCommand'),
    'New Dart descriptor from JSON',
  );
  check(
    compatibility.compatibilityIssues(spec, added).isEmpty,
    'Additive command compatible',
  );
  final output = g.render(spec);
  for (final entry in output.entries) {
    check(
      File(entry.key).readAsStringSync().replaceAll('\r\n', '\n') ==
          entry.value,
      'Stale artifact ${entry.key}',
    );
  }
  print(
    '${vectors.length} shared C/Dart vectors passed; scalar boundaries, assembly, schema, generation, compatibility and C++ checks passed.',
  );
}
