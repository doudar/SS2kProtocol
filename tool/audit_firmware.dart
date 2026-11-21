// Read-only check against an existing firmware checkout; never imports over the master.
import 'dart:convert';
import 'dart:io';

void main(List<String> args) {
  if (args.length != 1) {
    stderr.writeln(
      'Usage: dart tool/audit_firmware.dart <SmartSpin2k checkout>',
    );
    exitCode = 2;
    return;
  }
  final base = args.single;
  final spec = jsonDecode(File('protocol/ss2k.json').readAsStringSync());
  final h = File(
    '$base/lib/SS2K/include/CustomCharacteristicProtocol.h',
  ).readAsStringSync();
  final ids = {
    for (final m in RegExp(
      r'static const uint8_t (BLE_\w+)\s*=\s*(0x[0-9A-Fa-f]+);',
    ).allMatches(h))
      m[1]!: int.parse(m[2]!),
  };
  final formats = <String, String>{};
  final pending = <String>[];
  for (final m in RegExp(
    r'case (BLE_\w+):|return (Custom\w+);',
  ).allMatches(h)) {
    if (m[1] != null) pending.add(m[1]!);
    if (m[2] != null) {
      for (final name in pending) {
        formats[name] = m[2]!;
      }
      pending.clear();
    }
  }
  final issues = <String>[];
  if (ids.length != (spec['commands'] as List).length)
    issues.add(
      'Command count differs: firmware ${ids.length}, manifest ${(spec['commands'] as List).length}',
    );
  for (final c in spec['commands']) {
    if (ids[c['legacy_name']] != c['id'])
      issues.add('ID mismatch: ${c['legacy_name']}');
    if (formats[c['legacy_name']] != c['legacy_format'])
      issues.add('Format mismatch: ${c['legacy_name']}');
  }
  final settings = File('$base/include/settings.h').readAsStringSync();
  for (final entry in {
    'POWERTABLE_WATT_SIZE': 'power_table_columns',
    'POWERTABLE_CAD_SIZE': 'power_table_rows',
  }.entries) {
    final match = RegExp('#define ${entry.key} (\\d+)').firstMatch(settings);
    if (match == null || int.parse(match[1]!) != spec['constants'][entry.value])
      issues.add('${entry.key} mismatch');
  }
  if (issues.isNotEmpty) {
    stderr.writeln(issues.join('\n'));
    exitCode = 1;
  } else {
    print(
      'All ${ids.length} legacy IDs/formats and power-table dimensions match. Handler semantics still require review.',
    );
  }
}
