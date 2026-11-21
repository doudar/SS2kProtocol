/// Live two-companion test for a paired SmartSpin2k. This command accepts
/// two independent physical holds and revokes only the credentials it creates.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'secure_bench.dart' as hil;
import '../lib/ss2k_protocol.dart' as p;

class Companion {
  Companion(this.host, this.name);
  final String host, name;
  static final _random = Random.secure();
  final appId = List.generate(8, (_) => _random.nextInt(256));
  List<int>? root, deviceId;
  hil.Bench? link;
  Future<void> connect() async {
    final bench = hil.Bench(await hil.DirWire.connect(host), 234);
    try {
      final next = await bench.init(appId);
      if (deviceId != null && hil.hex(next) != hil.hex(deviceId!))
        throw StateError('Trainer identity changed');
      deviceId = next;
      link = bench;
    } catch (_) {
      await bench.wire.close();
      rethrow;
    }
  }

  Future<void> pair() async {
    stdout.writeln('Pairing companion $name');
    final bench = link!;
    root = await bench.pair();
    await bench.resume(root!);
  }

  Future<void> forget() async {
    final bench = link!;
    await bench.command(p.encodeAction(p.CommandId.forgetPeer));
    stdout.writeln('Authenticated forget acknowledged for $name');
    await close();
    await connect();
    final verifier = link!;
    await verifier.send(verifier.client.startSession(root!));
    final frame = await verifier.wire.receive().timeout(hil.deadline);
    if (hil.hex(frame) != 'af03')
      throw StateError('Revoked $name still recognized');
    root = null;
    stdout.writeln('Fresh connection rejects forgotten companion $name');
  }

  Future<void> close() async {
    final bench = link;
    if (bench != null) {
      bench.client.close();
      await bench.wire.close();
      link = null;
    }
  }
}

Future<void> main(List<String> args) async {
  if (args.length != 2)
    throw ArgumentError(
        'Usage: dart tool/secure_multi_peer_bench.dart HOST EXPECTED_DEVICE_NAME');
  final a = Companion(args[0], 'A'), b = Companion(args[0], 'B');
  try {
    await a.connect();
    await a.pair();
    final device = utf8.decode(
        (await a.link!.command(p.encodeRead(p.CommandId.deviceName)))
            .sublist(2));
    if (device != args[1])
      throw StateError('Unexpected paired trainer $device');
    print('Authenticated device name $device');
    await b.connect();
    if (hil.hex(a.deviceId!) != hil.hex(b.deviceId!))
      throw StateError('Different trainers');
    await b.pair();
    final versions = await Future.wait([a.link!.version(), b.link!.version()]);
    if (versions[0] != versions[1])
      throw StateError('Concurrent readers disagree');
    print('Two concurrent companions successfully read firmware version');
    await a.forget();
    await b.link!.version();
    print(
        'The second authenticated session still works after revoking the first');
    await b.forget();
  } finally {
    for (final peer in [a, b]) {
      if (peer.root != null) {
        // Only clean the random credentials made by this invocation.
        try {
          await peer.close();
          await peer.connect();
          await peer.link!.resume(peer.root!);
          await peer.forget();
        } catch (e) {
          stderr.writeln(
              'Test credential cleanup for ${peer.name} needs attention: $e');
        }
      }
      await peer.close();
    }
  }
}
