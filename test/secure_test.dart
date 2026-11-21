import 'dart:convert';
import 'dart:io';
import '../lib/secure.dart';
import '../lib/ss2k_protocol.dart' as p;

void check(bool value, String message) {
  if (!value) throw StateError(message);
}

String hex(List<int> bytes) =>
    bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
List<int> bytes(String value) => [
      for (int i = 0; i < value.length; i += 2)
        int.parse(value.substring(i, i + 2), radix: 16)
    ];
Future<Map<String, List<int>>> reference(Map<String, List<int>> args) async {
  final process = await Process.start(
      Platform.environment['PYTHON'] ?? 'python', ['test/reference_peer.py']);
  process.stdin.write(jsonEncode(args.map((k, v) => MapEntry(k, hex(v)))));
  await process.stdin.close();
  final output = await process.stdout.transform(utf8.decoder).join();
  final errors = await process.stderr.transform(utf8.decoder).join();
  check(await process.exitCode == 0, 'Reference failed: $errors');
  return (jsonDecode(output) as Map<String, dynamic>)
      .map((k, v) => MapEntry(k, bytes(v as String)));
}

void rejects(void Function() f, String message) {
  try {
    f();
  } catch (_) {
    return;
  }
  throw StateError(message);
}

Future<void> main() async {
  final vector = (jsonDecode(File('test/secure_vector.json').readAsStringSync())
          as Map<String, dynamic>)
      .map((k, v) => MapEntry(k, bytes(v as String)));
  final fixture =
      await reference({'hello': vector['a2']!, 'device_id': vector['device']!});
  final fixtureSession = await reference({
    'hello': vector['b0']!,
    'device_id': vector['device']!,
    'root': vector['root']!
  });
  for (final entry in {...fixture, ...fixtureSession}.entries) {
    check(hex(vector[entry.key]!) == hex(entry.value),
        'Independent golden vector mismatch');
  }
  final id = List.generate(8, (i) => i + 1),
      app = List.generate(8, (i) => 24 - i);
  final client = SecureClient(deviceId: id, appId: app);
  final a2 = client.startPair();
  final pair = await reference({'hello': a2, 'device_id': id});
  check(hex(client.acceptPairOffer(pair['offer']!)) == hex(pair['client']!),
      'Pair proof');
  check(
      hex(client.pendingPairKey) == hex(pair['root']!), 'Provisional pair key');
  final root = client.confirmPair(pair['paired']!);
  check(hex(root) == hex(pair['root']!), 'Committed pair key');
  Future<Map<String, List<int>>> connect() async {
    final b0 = client.startSession(root);
    final result =
        await reference({'hello': b0, 'device_id': id, 'root': root});
    check(
        hex(client.acceptChallenge(result['challenge']!)) ==
            hex(result['prove']!),
        'Client session proof');
    client.confirmSession(result['ready']!);
    return result;
  }

  final first = await connect();
  check(hex(client.seal([1, 0x25])) == hex(first['request']!),
      'Client CCM short record');
  check(hex(client.open(first['response']!)) == '802574657374',
      'Server CCM short record');
  rejects(() => client.open(first['response']!), 'Duplicate accepted');
  final chunk = [2, 0x38, 1, 0, 4, 0, 0, ...List.generate(2048, (i) => i & 255)];
  p.validateRequest(chunk, dirConOta: true);
  p.validateRequest(chunk.sublist(0, 8), dirConOta: true);
  p.validateRequest(chunk.sublist(0, 512));
  rejects(() => p.validateRequest(chunk.sublist(0, 513)), 'Legacy chunk bound');
  rejects(() => client.seal(chunk), 'Generic sealing accepted a large record');
  for (final invalid in [
    chunk.sublist(0, 7),
    [...chunk, 0],
    [...chunk]..[0] = p.read,
    [...chunk]..[1] = p.CommandId.deviceName,
    [...chunk]..[2] = p.ota_finish,
  ]) {
    rejects(() => p.validateRequest(invalid, dirConOta: true), 'Invalid extended chunk');
    rejects(() => client.seal(invalid, dirConOta: true), 'Invalid extended sealing');
  }
  final extended = client.seal(chunk, dirConOta: true);
  check(extended.length == p.dircon_ota_max_wire &&
      hex(extended) == hex(first['dircon_chunk']!), 'Full-size DirCon CCM vector');
  rejects(() => secureFragments(extended, 234).toList(), 'Fragmented large record');
  rejects(() => SecureAssembler().add(extended), 'Large inbound server frame');
  rejects(() => client.open(extended), 'Large server record');
  final second = await connect();
  check(hex(first['challenge']!) != hex(second['challenge']!),
      'Session freshness');
  rejects(() => client.open(first['response']!),
      'Previous-session record accepted');
  check(!client.authenticated, 'Failed tag must terminate session');
  final third = await connect();
  final changed = List<int>.of(third['response']!)..last ^= 1;
  rejects(() => client.open(changed), 'Damaged tag accepted');
  rejects(() => client.open(third['response']!), 'Failed connection reused');
  client.startPair();
  rejects(() => client.acceptPairOffer([0xa3, 4, ...List.filled(64, 0)]),
      'Invalid ECDH point accepted');
  client.startPair();
  rejects(() => client.acceptPairOffer([0xa3, 4, ...List.filled(64, 255)]),
      'Noncanonical ECDH point accepted');
  client.startSession(root);
  rejects(() => client.acceptChallenge(first['challenge']!),
      'Wrong server proof accepted');
  for (final size in [20, 21, 65, 234, 512]) {
    final assembler = SecureAssembler();
    final payload = [p.secure_data, ...List.generate(524, (i) => i & 255)];
    final chunks = secureFragments(payload, size).toList();
    for (final chunk in chunks.take(chunks.length - 1)) {
      check(assembler.add(chunk) == null, 'Premature assembly');
    }
    check(
        hex(assembler.add(chunks.last)!) == hex(payload), 'Fragment roundtrip');
    assembler.add(chunks.first);
    rejects(() => assembler.add(chunks.first), 'Duplicate fragment accepted');
    rejects(() => assembler.add(chunks.last), 'Orphan fragment accepted');
    check(assembler.add([p.secure_info])!.single == p.secure_info,
        'Fragment cleanup');
  }
  print(
      'Independent P-256, HKDF, HMAC, AES-CCM, session lifecycle and fragment checks passed.');
}
