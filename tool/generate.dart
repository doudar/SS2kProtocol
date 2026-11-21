import 'dart:convert';
import 'dart:io';
import 'schema_validator.dart';

const formatNames = [
  'none',
  'empty',
  'bool',
  'u16',
  'i16',
  'i32',
  'string',
  'row_index',
  'power_table',
  'gear_index',
  'gear_write',
  'gear_reply',
  'snapshot',
  'scan',
];
const legacyNames = [
  'CustomAction',
  'CustomBoolean',
  'CustomUnsigned16',
  'CustomSigned16',
  'CustomSigned32',
  'CustomString',
  'CustomPowerTableRow',
  'CustomSettingsSnapshot',
  'CustomScanResultStream',
  'CustomBooleanWriteStringRead',
  'CustomGearTeeth',
  'CustomUnknown',
];
String upper(String s) => s
    .replaceAllMapped(RegExp(r'([a-z0-9])([A-Z])'), (m) => '${m[1]}_${m[2]}')
    .toUpperCase();
String quote(Object? value) => jsonEncode(value).replaceAll(r'$', r'\$');
String cf(dynamic f) => 'SS2K_FORMAT_${(f ?? 'none').toString().toUpperCase()}';
String df(dynamic f) => 'WireFormat.${f ?? 'none'}';

Never invalid(String message) => throw FormatException(message);
void validate(Map<String, dynamic> s) {
  validateSchema(
    s,
    jsonDecode(File('protocol/schema.json').readAsStringSync()),
  );
  if (s['schema_version'] != 1 ||
      !RegExp(r'^\d+\.\d+\.\d+$').hasMatch(s['version'] as String))
    invalid('Unsupported schema/version');
  for (final key in ['service_uuid', 'characteristic_uuid']) {
    if (!RegExp(
      r'^[0-9a-f]{8}-(?:[0-9a-f]{4}-){3}[0-9a-f]{12}$',
    ).hasMatch(s[key] as String))
      invalid('Invalid $key');
  }
  if (s['byte_order'] != 'little') invalid('Only little endian is supported');
  final op = (s['operations'] as Map).values.toList();
  final status = (s['statuses'] as Map).values.toList();
  for (final values in [op, status]) {
    if (values.toSet().length != values.length ||
        values.any((v) => v is! int || v < 0 || v > 255))
      invalid('Invalid operation/status codes');
  }
  final ids = <int>{};
  final names = <String>{};
  final cNames = <String>{};
  final keys = <String>{};
  final orders = <int>{};
  for (final r in s['reserved_ids']) {
    if (r['id'] is! int || r['id'] < 1 || r['id'] > 255 || !ids.add(r['id']))
      invalid('Invalid reserved ID');
  }
  for (final c in s['commands']) {
    final id = c['id'];
    if (id is! int || id < 1 || id > 255 || !ids.add(id))
      invalid('Duplicate/invalid/reserved command ID: $id');
    if (!RegExp(r'^[A-Za-z][A-Za-z0-9_]*$').hasMatch(c['name']) ||
        !names.add(c['name']))
      invalid('Invalid/duplicate name');
    if (!cNames.add(upper(c['name'])))
      invalid('Command names collide after C normalization');
    if (c['legacy_name'] != 'BLE_${c['name']}' ||
        !legacyNames.contains(c['legacy_format']))
      invalid('Invalid legacy mapping');
    if (c['scale'] is! int || c['scale'] < 1 || c['scale'] > 65535)
      invalid('Invalid scale');
    for (final field in [
      'read_request',
      'read_response',
      'write_request',
      'write_response',
      'notification',
    ]) {
      if (c[field] != null &&
          (!formatNames.contains(c[field]) || c[field] == 'none'))
        invalid('Unknown format $field');
    }
    if ((c['read_request'] == null) != (c['read_response'] == null) ||
        (c['write_request'] == null) != (c['write_response'] == null))
      invalid('Unpaired request/response');
    if (!['response', 'notification', null].contains(c['write_completion']) ||
        (c['write_request'] == null) != (c['write_completion'] == null))
      invalid('Invalid completion');
    if (c['write_completion'] == 'notification' && c['notification'] == null)
      invalid('Missing completion notification');
    if (!['active', 'deprecated'].contains(c['status']))
      invalid('Invalid command status');
    if (c['snapshot_key'] != null && !keys.add(c['snapshot_key']))
      invalid('Duplicate snapshot key');
    if (c['app'] != null && !orders.add(c['app']['order']))
      invalid('Duplicate app order');
    final shape = <String, List<String>>{
      'CustomAction': ['none', 'empty', 'empty'],
      'CustomBoolean': ['bool', 'bool', 'bool'],
      'CustomUnsigned16': ['u16', 'u16', 'u16'],
      'CustomSigned16': ['i16', 'i16', 'i16'],
      'CustomSigned32': ['i32', 'i32', 'i32'],
      'CustomString': ['string', 'string', 'string'],
      'CustomPowerTableRow': ['power_table', 'power_table', 'power_table'],
      'CustomSettingsSnapshot': ['snapshot', 'none', 'none'],
      'CustomScanResultStream': ['none', 'none', 'none'],
      'CustomBooleanWriteStringRead': ['string', 'bool', 'bool'],
      'CustomGearTeeth': ['gear_reply', 'gear_write', 'gear_reply'],
    }[c['legacy_format']];
    if (shape == null) invalid('Assigned commands cannot use CustomUnknown');
    for (var i = 0; i < 3; i++) {
      final field = ['read_response', 'write_request', 'write_response'][i];
      if (c[field] != null && c[field] != shape[i])
        invalid('Legacy format disagrees with $field');
    }
    if (c['read_request'] != null) {
      final expected = c['read_response'] == 'power_table'
          ? 'row_index'
          : c['read_response'] == 'gear_reply'
          ? 'gear_index'
          : 'empty';
      if (c['read_request'] != expected)
        invalid('Read selector disagrees with response format');
    }
    if (c['notification'] != null &&
        c['notification'] !=
            (c['legacy_format'] == 'CustomScanResultStream'
                ? 'scan'
                : shape[0]))
      invalid('Notification format disagrees with legacy type');
  }
  final k = s['constants'] as Map;
  for (final entry in k.entries) {
    if (!RegExp(r'^[a-z][a-z0-9_]*$').hasMatch(entry.key) ||
        entry.value is! int)
      invalid('Invalid constant');
  }
  // These are versioned layouts implemented by the runtime. Changes require a codec update.
  if (k['snapshot_header_length'] != 7 || k['scan_header_length'] != 10)
    invalid('Header layout requires codec update');
  if (k['power_table_rows'] < 1 ||
      k['power_table_rows'] > 256 ||
      k['power_table_columns'] < 1 ||
      k['power_table_columns'] > 255 ||
      k['gear_max_count'] < 2 ||
      k['gear_max_count'] > 255)
    invalid('Invalid array limits');
  for (final name in ['snapshot_version', 'scan_version']) {
    if (k[name] < 1 || k[name] > 255) invalid('Invalid framing version');
  }
  if (k['scan_begin'] != 0 || k['scan_device'] != 1 || k['scan_end'] != 2)
    invalid('Unsupported scan event grammar');
  if (k['gear_pair_multiplier'] != 100 ||
      k['gear_ratio_scale'] != 1000 ||
      k['gear_max_tooth'] != 99 ||
      k['gear_min_ratio'] <= 0 ||
      k['gear_max_ratio'] < k['gear_min_ratio'])
    invalid('Unsupported gear packing');
}

Map<String, String> render(Map<String, dynamic> s) {
  validate(s);
  final commands = List<Map<String, dynamic>>.from(s['commands'])
    ..sort((a, b) => a['id'].compareTo(b['id']));
  final k = s['constants'] as Map;
  final h = StringBuffer(
    '/* GENERATED by tool/generate.dart from protocol/ss2k.json. DO NOT EDIT. */\n#ifndef SS2K_PROTOCOL_GENERATED_H\n#define SS2K_PROTOCOL_GENERATED_H\n#include <stdint.h>\n',
  );
  h.writeln('#define SS2K_PROTOCOL_VERSION ${jsonEncode(s['version'])}');
  h.writeln(
    '#define SS2K_SERVICE_UUID ${jsonEncode(s['service_uuid'])}\n#define SS2K_CHARACTERISTIC_UUID ${jsonEncode(s['characteristic_uuid'])}',
  );
  for (final group in ['operations', 'statuses', 'constants']) {
    for (final e in (s[group] as Map).entries) {
      h.writeln('#define SS2K_${upper(e.key)} (${e.value})');
    }
  }
  h.writeln('typedef enum {');
  for (final f in formatNames) {
    h.writeln('  ${cf(f)},');
  }
  h.writeln('} ss2k_format;');
  for (final c in commands) {
    h.writeln(
      '#define SS2K_ID_${upper(c['name'])} (0x${c['id'].toRadixString(16).padLeft(2, '0')})',
    );
  }
  h.writeln('#define SS2K_COMMAND_COUNT ${commands.length}\n#endif');

  final table = StringBuffer('/* GENERATED. DO NOT EDIT. */\n');
  for (final c in commands) {
    table.writeln(
      '  {${c['id']}, ${['read_request', 'read_response', 'write_request', 'write_response', 'notification'].map((f) => cf(c[f])).join(', ')}, ${c['scale']}, ${c['write_completion'] == 'notification' ? 1 : 0}},',
    );
  }
  final compat = StringBuffer(
    '/* GENERATED compatibility bridge. Opt in by including this header. */\n#ifndef SS2K_LEGACY_PROTOCOL_H\n#define SS2K_LEGACY_PROTOCOL_H\n#include "ss2k_protocol.h"\n',
  );
  for (final e in (s['operations'] as Map).entries) {
    compat.writeln('#define cc_${e.key} SS2K_${upper(e.key)}');
  }
  for (final e in (s['statuses'] as Map).entries) {
    compat.writeln('#define cc_${e.key} SS2K_${upper(e.key)}');
  }
  for (final c in commands) {
    compat.writeln(
      '#define ${c['legacy_name']} SS2K_ID_${upper(c['name'])}',
    );
  }
  compat.writeln(
    'typedef enum { ${legacyNames.join(', ')} } CustomCharacteristicValueFormat;\nstatic inline CustomCharacteristicValueFormat customCharacteristicValueFormat(uint8_t id) {\n  switch (id) {',
  );
  for (final c in commands) {
    compat.writeln('    case ${c['id']}: return ${c['legacy_format']};');
  }
  compat.writeln('    default: return CustomUnknown;\n  }\n}\n#endif');

  final dart = StringBuffer(
    '// GENERATED by tool/generate.dart. DO NOT EDIT.\npart of ss2k_protocol;\n',
  );
  dart.writeln(
    'const protocolVersion = ${quote(s['version'])};\nconst serviceUuid = ${quote(s['service_uuid'])};\nconst characteristicUuid = ${quote(s['characteristic_uuid'])};',
  );
  for (final group in ['operations', 'statuses', 'constants']) {
    for (final e in (s[group] as Map).entries) {
      dart.writeln('const int ${e.key} = ${e.value};');
    }
  }
  dart.writeln(
    'enum WireFormat { ${formatNames.join(', ')} }\nabstract final class CommandId {',
  );
  for (final c in commands) {
    dart.writeln('  static const int ${c['name']} = ${c['id']};');
  }
  dart.writeln('}\nconst commands = <int, CommandDescriptor>{');
  for (final c in commands) {
    dart.writeln(
      '  ${c['id']}: CommandDescriptor(${c['id']}, ${quote(c['name'])}, ${['read_request', 'read_response', 'write_request', 'write_response', 'notification'].map((f) => df(c[f])).join(', ')}, ${c['scale']}, ${quote(c['snapshot_key'])}, ${c['write_completion'] == 'notification'}, ${c['sensitive']}),',
    );
  }
  dart.writeln('};\nconst appDescriptors = <Map<String, Object?>>[');
  final appCommands = commands.where((c) => c['app'] != null).toList()
    ..sort((a, b) => a['app']['order'].compareTo(b['app']['order']));
  for (final c in appCommands) {
    final a = Map<String, dynamic>.from(c['app'])
      ..remove('order')
      ..remove('settingsSnapshotKey');
    a['reference'] =
        '0x${c['id'].toRadixString(16).padLeft(2, '0').toUpperCase()}';
    a['settingsSnapshotKey'] = c['snapshot_key'];
    dart.writeln('  ${quote(a)},');
  }
  dart.writeln('];');

  final docs = StringBuffer(
    '# SmartSpin2k custom characteristic\n\nGenerated from `protocol/ss2k.json`, version ${s['version']}. Do not edit this file.\n\nService: `${s['service_uuid']}`  \nCharacteristic: `${s['characteristic_uuid']}`\n\n## Framing and behavior\n\n',
  );
  for (final n in s['transport_notes']) {
    docs.writeln('- $n\n');
  }
  docs.writeln(
    '## Command index\n\nScale means **wire integer = engineering value × scale**. UI ranges are not wire limits. A dash means unsupported.\n\n| ID | Name | Read request → response | Write request → response | Notify | Scale | Snapshot key |\n|---|---|---|---|---|---|---|',
  );
  for (final c in commands) {
    docs.writeln(
      '| `0x${c['id'].toRadixString(16).padLeft(2, '0').toUpperCase()}` | ${c['name']} | ${c['read_request'] ?? '—'} → ${c['read_response'] ?? '—'} | ${c['write_request'] ?? '—'} → ${c['write_response'] ?? '—'} | ${c['notification'] ?? '—'} | ${c['scale']} | ${c['snapshot_key'] ?? '—'} |',
    );
  }
  for (final r in s['reserved_ids']) {
    docs.writeln('\nReserved `0x${r['id'].toRadixString(16)}`: ${r['reason']}');
  }
  docs.writeln(
    '\n## Payload formats\n\n`empty`: no bytes. `bool`: one byte; zero false, nonzero true on receive. `u16`/`i16`/`i32`: exactly 2/2/4 little-endian bytes. `string`: all remaining bytes. `row_index`: one row byte. `power_table`: row byte + ${k['power_table_columns']} signed LE16 values. `gear_index`: empty metadata request or one index byte. `gear_write`: count byte + count LE16 pairs. `gear_reply`: count byte, optionally index byte + LE16 pair. `snapshot` and `scan`: full headers described above (the status/ID are included in header lengths).\n',
  );
  docs.writeln('## Command details\n');
  for (final c in commands) {
    docs.writeln(
      '### ${c['legacy_name']} (`0x${c['id'].toRadixString(16).padLeft(2, '0')}`)\n\n${c['description']}. Status: ${c['status']}.${c['unit'] == null ? '' : ' Unit: ${c['unit']}.'}\n\n${c['notes']}\n',
    );
  }
  return {
    'c/include/ss2k_protocol_generated.h': h.toString(),
    'c/src/descriptors.inc': table.toString(),
    'c/include/CustomCharacteristicProtocol.h': compat.toString(),
    'lib/src/generated.dart': dart.toString(),
    'docs/protocol.md': docs.toString(),
    'pubspec.yaml':
        '# GENERATED by tool/generate.dart.\nname: ss2k_protocol\ndescription: SmartSpin2k custom characteristic definitions and portable codecs.\nversion: ${s['version']}\nenvironment:\n  sdk: ">=3.3.0 <4.0.0"\n',
    'library.json':
        '${const JsonEncoder.withIndent('  ').convert({
          'name': 'SS2kProtocol',
          'version': s['version'],
          'description': 'Portable SmartSpin2k custom characteristic protocol',
          'license': 'GPL-2.0-only',
          'frameworks': '*',
          'platforms': '*',
          'build': {'srcDir': 'c/src', 'includeDir': 'c/include'},
        })}\n',
  };
}

void main(List<String> args) {
  if (args.any((a) => a != '--check')) {
    stderr.writeln('Usage: dart tool/generate.dart [--check]');
    exitCode = 2;
    return;
  }
  final s =
      jsonDecode(File('protocol/ss2k.json').readAsStringSync())
          as Map<String, dynamic>;
  final outputs = render(s);
  var stale = false;
  for (final entry in outputs.entries) {
    final file = File(entry.key);
    if (args.contains('--check')) {
      if (!file.existsSync() ||
          file.readAsStringSync().replaceAll('\r\n', '\n') != entry.value) {
        stderr.writeln('Stale: ${entry.key}');
        stale = true;
      }
    } else {
      file.parent.createSync(recursive: true);
      file.writeAsStringSync(entry.value);
    }
  }
  if (stale) {
    exitCode = 1;
  } else {
    stdout.writeln(
      '${args.contains('--check') ? 'Verified' : 'Generated'} ${outputs.length} artifacts.',
    );
  }
}
