import 'dart:convert';
import 'dart:io';
import 'generate.dart' show validate;

List<String> compatibilityIssues(
  Map<String, dynamic> previous,
  Map<String, dynamic> current,
) {
  final issues = <String>[];
  for (final field in [
    'service_uuid',
    'characteristic_uuid',
    'operations',
    'statuses',
    'byte_order',
    'constants',
  ]) {
    // Canonicalize maps so whitespace and property ordering do not matter.
    if (_canonical(previous[field]) != _canonical(current[field]))
      issues.add('Changed $field');
  }
  final next = {for (final c in current['commands']) c['id']: c};
  final reserved = {for (final r in current['reserved_ids']) r['id']};
  for (final old in previous['reserved_ids']) {
    if (!reserved.contains(old['id']))
      issues.add('Removed reserved ID ${old['id']}');
  }
  for (final old in previous['commands']) {
    final c = next[old['id']];
    if (c == null) {
      issues.add('Removed command ${old['name']}');
      continue;
    }
    for (final field in [
      'name',
      'legacy_name',
      'legacy_format',
      'read_request',
      'read_response',
      'write_request',
      'write_response',
      'notification',
      'write_completion',
      'scale',
      'snapshot_key',
    ]) {
      if (c[field] != old[field]) issues.add('${old['name']}: changed $field');
    }
  }
  return issues;
}

String _canonical(Object? value) {
  if (value is Map) {
    final keys = value.keys.cast<String>().toList()..sort();
    return '{${keys.map((k) => '${jsonEncode(k)}:${_canonical(value[k])}').join(',')}}';
  }
  if (value is List) return '[${value.map(_canonical).join(',')}]';
  return jsonEncode(value);
}

void main(List<String> args) {
  if (args.length != 1) {
    stderr.writeln(
      'Usage: dart tool/check_compatibility.dart <previous ss2k.json>',
    );
    exitCode = 2;
    return;
  }
  final previous =
      jsonDecode(File(args[0]).readAsStringSync()) as Map<String, dynamic>;
  final current =
      jsonDecode(File('protocol/ss2k.json').readAsStringSync())
          as Map<String, dynamic>;
  validate(previous);
  validate(current);
  final issues = compatibilityIssues(previous, current);
  if (issues.isNotEmpty) {
    stderr.writeln(issues.join('\n'));
    exitCode = 1;
  } else {
    stdout.writeln('Existing wire contracts and reserved IDs preserved.');
  }
}
