// Dependency-free evaluator for the JSON Schema vocabulary used by schema.json.
// Unknown assertion keywords fail closed; this is not a general JSON Schema engine.
import 'dart:convert';

void validateSchema(
  Object? value,
  Map<String, dynamic> schema, {
  Map<String, dynamic>? root,
  String path = r'$',
}) {
  root ??= schema;
  const supported = {
    r'$schema',
    r'$defs',
    'title',
    'description',
    r'$ref',
    'type',
    'const',
    'enum',
    'required',
    'properties',
    'additionalProperties',
    'items',
    'minItems',
    'minimum',
    'maximum',
    'pattern',
  };
  for (final key in schema.keys) {
    if (!supported.contains(key))
      throw FormatException('Unsupported schema keyword: $key');
  }
  Never fail(String text) => throw FormatException('$path: $text');
  if (schema.containsKey(r'$ref')) {
    final ref = schema[r'$ref'] as String;
    if (!ref.startsWith('#/')) fail('Only local schema references supported');
    Object? target = root;
    for (final part in ref.substring(2).split('/')) {
      target =
          (target as Map)[part.replaceAll('~1', '/').replaceAll('~0', '~')];
    }
    validateSchema(
      value,
      Map<String, dynamic>.from(target as Map),
      root: root,
      path: path,
    );
  }
  if (schema.containsKey('const') &&
      jsonEncode(value) != jsonEncode(schema['const']))
    fail('Wrong constant');
  if (schema.containsKey('enum') &&
      !(schema['enum'] as List).any((v) => jsonEncode(v) == jsonEncode(value)))
    fail('Not in enum');
  bool isType(String type) => switch (type) {
    'object' => value is Map,
    'array' => value is List,
    'string' => value is String,
    'integer' => value is int,
    'number' => value is num,
    'boolean' => value is bool,
    'null' => value == null,
    _ => throw FormatException('Unsupported schema type: $type'),
  };
  if (schema.containsKey('type')) {
    final types = schema['type'] is List
        ? schema['type'] as List
        : [schema['type']];
    if (!types.any((t) => isType(t as String))) fail('Wrong type');
  }
  if (value is num) {
    if (schema.containsKey('minimum') && value < schema['minimum'])
      fail('Below minimum');
    if (schema.containsKey('maximum') && value > schema['maximum'])
      fail('Above maximum');
  }
  if (value is String &&
      schema.containsKey('pattern') &&
      !RegExp(schema['pattern']).hasMatch(value))
    fail('Pattern mismatch');
  if (value is List) {
    if (schema.containsKey('minItems') && value.length < schema['minItems'])
      fail('Too few items');
    if (schema.containsKey('items')) {
      for (var i = 0; i < value.length; i++) {
        validateSchema(
          value[i],
          schema['items'],
          root: root,
          path: '$path[$i]',
        );
      }
    }
  }
  if (value is Map) {
    for (final key in schema['required'] ?? []) {
      if (!value.containsKey(key)) fail('Missing $key');
    }
    final properties = schema['properties'] as Map? ?? {};
    for (final key in value.keys) {
      if (properties.containsKey(key)) {
        validateSchema(
          value[key],
          properties[key],
          root: root,
          path: '$path.$key',
        );
      } else if (schema['additionalProperties'] == false) {
        fail('Unknown property $key');
      } else if (schema['additionalProperties'] is Map) {
        validateSchema(
          value[key],
          schema['additionalProperties'],
          root: root,
          path: '$path.$key',
        );
      }
    }
  }
}
