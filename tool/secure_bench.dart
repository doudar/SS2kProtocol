/// Live interop with the production Dart crypto. Run --help for usage.
/// Credentials live in memory and are never logged.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';
import 'package:pointycastle/export.dart' show SHA256Digest;
import '../lib/secure.dart';
import '../lib/ss2k_protocol.dart' as p;

String hex(List<int> bytes) =>
    bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
List<int> unhex(String value) {
  if (!RegExp(r'^(?:[0-9a-fA-F]{2})+$').hasMatch(value))
    throw const FormatException('Invalid helper frame');
  return [
    for (int i = 0; i < value.length; i += 2)
      int.parse(value.substring(i, i + 2), radix: 16)
  ];
}

List<int> u32(int n) => [for (int i = 0; i < 4; i++) (n >>> (i * 8)) & 255];
const deadline = Duration(seconds: 75);

class PeerDisconnected implements Exception {
  const PeerDisconnected();
}

abstract interface class Wire {
  Future<void> send(List<int> wire);
  Future<List<int>> receive();
  Future<void> close();
}

class BleWire implements Wire {
  BleWire(this.child, this.events);
  final Process child;
  final StreamIterator<String> events;
  static Future<BleWire> connect(String script, String python) async {
    final child = await Process.start(python, ['-B', '-u', script]);
    child.stderr.transform(utf8.decoder).listen(stderr.write);
    final events = StreamIterator(
        child.stdout.transform(utf8.decoder).transform(const LineSplitter()));
    final wire = BleWire(child, events);
    try {
      if (!await events.moveNext().timeout(deadline) ||
          events.current != 'READY')
        throw StateError('BLE helper failed to subscribe');
      return wire;
    } catch (_) {
      await wire.close();
      rethrow;
    }
  }

  @override
  Future<void> send(List<int> wire) async {
    child.stdin.writeln(hex(wire));
    await child.stdin.flush();
  }

  @override
  Future<List<int>> receive() async {
    if (!await events.moveNext()) throw const PeerDisconnected();
    if (events.current == 'DISCONNECTED') throw const PeerDisconnected();
    return unhex(events.current);
  }

  @override
  Future<void> close() async {
    await child.stdin
        .close()
        .timeout(const Duration(seconds: 2), onTimeout: () => null);
    try {
      await child.exitCode.timeout(const Duration(seconds: 5));
    } on TimeoutException {
      child.kill();
    }
    await events.cancel();
  }
}

class DirWire implements Wire {
  DirWire(this.socket) : events = StreamIterator(socket);
  final Socket socket;
  final StreamIterator<Uint8List> events;
  final List<int> buffer = [];
  final List<List<int>> pending = [];
  final uuid = unhex(p.characteristicUuid.replaceAll('-', ''));
  int sequence = 0;
  static Future<DirWire> connect(String host) async {
    final socket =
        await Socket.connect(host, 8081, timeout: const Duration(seconds: 4));
    socket.setOption(SocketOption.tcpNoDelay, true);
    final wire = DirWire(socket);
    try {
      await wire.request(5, [1]);
      return wire;
    } catch (_) {
      await wire.close();
      rethrow;
    }
  }

  Future<List<int>> nextFrame() async {
    while (
        buffer.length < 6 || buffer.length < 6 + 256 * buffer[4] + buffer[5]) {
      if (!await events.moveNext()) throw const PeerDisconnected();
      buffer.addAll(events.current);
    }
    final size = 6 + 256 * buffer[4] + buffer[5],
        frame = buffer.sublist(0, size);
    buffer.removeRange(0, size);
    if (frame[0] != 1 ||
        frame[3] != 0 ||
        size < 22 ||
        hex(frame.sublist(6, 22)) != hex(uuid)) {
      throw StateError(
          'Unexpected DirCon reply (operation ${frame[1]}, status ${frame[3]})');
    }
    return frame;
  }

  Future<void> request(int op, List<int> data) async {
    sequence = (sequence % 255) + 1;
    final l = 16 + data.length;
    socket.add([1, op, sequence, 0, l >> 8, l & 255, ...uuid, ...data]);
    await socket.flush();
    while (true) {
      final frame = await nextFrame().timeout(deadline);
      final value = frame.sublist(22);
      if (frame[1] == 6) {
        if (value.isNotEmpty) pending.add(value);
        continue;
      }
      if (frame[1] != op || frame[2] != sequence)
        throw StateError('Unmatched DirCon reply');
      if (value.isNotEmpty) pending.add(value);
      return;
    }
  }

  @override
  Future<void> send(List<int> wire) => request(4, wire);
  @override
  Future<List<int>> receive() async {
    if (pending.isNotEmpty) return pending.removeAt(0);
    final frame = await nextFrame();
    if (frame[1] != 6) throw StateError('Unexpected asynchronous DirCon reply');
    return frame.sublist(22);
  }

  @override
  Future<void> close() async {
    socket.destroy();
    await events.cancel();
  }
}

class Bench {
  Bench(this.wire, this.mtu);
  final Wire wire;
  final int mtu;
  final assembler = SecureAssembler();
  late SecureClient client;
  Future<void> send(List<int> packet) async {
    for (final fragment in secureFragments(packet, mtu)) {
      await wire.send(fragment);
    }
  }

  Future<List<int>> next() async {
    while (true) {
      final record = assembler.add(await wire.receive().timeout(deadline));
      if (record == null) continue;
      if (record.first == p.secure_error)
        throw StateError(
            'Firmware secure error ${record.length > 1 ? record[1] : -1}');
      return record;
    }
  }

  Future<List<int>> exchange(List<int> request) async {
    await send(request);
    return next();
  }

  Future<List<int>> init(List<int> appId) async {
    final caps = await exchange(p.encodeRead(p.CommandId.capabilities));
    if (caps.length != 7 ||
        caps[0] != p.success ||
        caps[1] != p.CommandId.capabilities ||
        caps[2] != p.capabilities_version ||
        caps[3] & p.cap_secure_settings == 0) {
      throw StateError('Device did not advertise secure configuration');
    }
    final id = secureDeviceId(await exchange(secureInfoRequest()));
    client = SecureClient(deviceId: id, appId: appId);
    return id;
  }

  Future<List<int>> pair() async {
    await send(client.startPair());
    stdout.writeln('PAIR PENDING: press and hold both shifter buttons now.');
    final confirm = client.acceptPairOffer(await next());
    return client.confirmPair(await exchange(confirm));
  }

  Future<void> resume(List<int> root) async {
    final proof =
        client.acceptChallenge(await exchange(client.startSession(root)));
    client.confirmSession(await exchange(proof));
  }

  Future<List<int>> command(List<int> inner) async {
    await send(client.seal(inner));
    while (true) {
      final reply = client.open(await next());
      if (reply[0] == p.secure_notification || reply[1] != inner[1]) continue;
      if (reply[0] != p.success)
        throw StateError('Firmware rejected inner command ${inner[1]}');
      return reply;
    }
  }

  Future<String> version() async {
    final reply = await command(p.encodeRead(p.CommandId.firmwareVer));
    final version = utf8.decode(reply.sublist(2));
    stdout.writeln('Authenticated firmware version $version');
    return version;
  }

  /// A fresh TCP connection or a BLE reconnection can precede a delayed
  /// reboot. Observe loss of the old live connection before accepting a boot.
  Future<void> observeReboot() async {
    Future<void> untilPeerCloses() async {
      try {
        while (true) {
          await wire.receive();
        }
      } on PeerDisconnected {
        return;
      } on SocketException {
        return;
      }
    }

    await untilPeerCloses().timeout(const Duration(seconds: 20),
        onTimeout: () => throw StateError(
            'Finished image, but the old connection did not disconnect'));
    stdout.writeln('Observed firmware reboot disconnect.');
  }

  Future<void> ota(String path, String oldVersion, String? expected) async {
    final image = await File(path).readAsBytes();
    if (image.isEmpty || image.length > 0xffffffff)
      throw ArgumentError('Invalid image size');
    final digest = SHA256Digest().process(image);
    stdout.writeln('Streaming image SHA-256 ${hex(digest)}');
    if (expected != null) {
      if (expected.isEmpty || expected == oldVersion)
        throw ArgumentError(
            'Expected post-update version must differ from the current build');
      // Firmware uses a NUL-terminated FIRMWARE_VERSION literal in the image.
      if (!latin1.decode(image).contains('$expected\x00'))
        throw ArgumentError(
            'Expected version string absent from candidate image');
    }
    Future<void> op(int n, List<int> body, int offset) async {
      final reply = await command(
          p.encodeRequest(p.write, p.CommandId.firmwareStream, [n, ...body]));
      if (reply.length != 7 ||
          reply[2] != n ||
          hex(reply.sublist(3)) != hex(u32(offset)))
        throw StateError('Unexpected firmware stream acknowledgement');
    }

    await op(p.ota_begin, [...u32(image.length), ...digest], 0);
    // At minimum ATT capacity the initial OTA request already needs fragments;
    // transmit a full bounded plaintext record instead of one byte per ACK.
    final room = mtu <= p.secure_overhead + 7
        ? p.secure_max_inner - 7
        : min(p.secure_max_inner - 7, mtu - p.secure_overhead - 7);
    int nextLog = 0;
    for (int offset = 0; offset < image.length; offset += room) {
      final end = min(image.length, offset + room);
      await op(
          p.ota_chunk, [...u32(offset), ...image.getRange(offset, end)], end);
      if (end >= nextLog) {
        stdout.writeln('OTA ${100 * end ~/ image.length}%');
        nextLog = end + 262144;
      }
    }
    await op(p.ota_finish, [], image.length);
    stdout.writeln('Firmware finish acknowledged.');
  }
}

Future<void> main(List<String> args) async {
  String? opt(String name) {
    final i = args.indexOf(name);
    return i < 0 ? null : args[i + 1];
  }

  final host = opt('--host'), helper = opt('--ble-helper');
  if (args.contains('--help') || (host == null && helper == null)) {
    stdout.writeln(
        'dart tool/secure_bench.dart [--host HOST] [--ble-helper PATH --python EXE] [--ble-wire BYTES] [--ota-ble APP.bin --expect-ble VERSION] [--ota-dircon APP.bin --expect-dircon VERSION] [--forget]');
    stdout.writeln(
        'Pairs on BLE first when both transports are supplied, reconnects on each, then optionally updates and forgets the test peer.');
    return;
  }
  final rng = Random.secure(), app = List.generate(8, (_) => rng.nextInt(256));
  List<int>? root, identity;
  final transports = [if (helper != null) 'ble', if (host != null) 'dircon'];
  for (final transport in transports) {
    Future<Bench> connect() async {
      final wire = transport == 'ble'
          ? await BleWire.connect(helper!, opt('--python') ?? 'python')
          : await DirWire.connect(host!);
      final bench = Bench(wire,
          transport == 'ble' ? int.parse(opt('--ble-wire') ?? '20') : 234);
      try {
        final id = await bench.init(app);
        if (identity != null && hex(id) != hex(identity!))
          throw StateError('Transports reported different devices');
        identity = id;
        return bench;
      } catch (_) {
        await wire.close();
        rethrow;
      }
    }

    stdout.writeln('Connecting via $transport');
    var bench = await connect();
    try {
      root ??= await bench.pair();
      await bench.resume(root);
      await bench.version();
    } finally {
      bench.client.close();
      await bench.wire.close();
    }
    stdout.writeln('Reconnecting via $transport');
    await Future<void>.delayed(const Duration(seconds: 1));
    bench = await connect();
    final path = opt('--ota-$transport');
    final expected = opt('--expect-$transport');
    try {
      await bench.resume(root);
      final oldVersion = await bench.version();
      if (path != null) {
        await bench.ota(path, oldVersion, expected);
        await bench.observeReboot();
      }
    } finally {
      bench.client.close();
      await bench.wire.close();
    }
    if (path != null) {
      Object? last;
      var ready = false;
      for (int i = 0; i < 12 && !ready; i++) {
        await Future<void>.delayed(const Duration(seconds: 3));
        Bench? restarted;
        try {
          restarted = await connect();
          await restarted.resume(root);
          final actual = await restarted.version();
          if (expected != null && actual != expected)
            throw StateError('Booted $actual, expected $expected');
          ready = true;
        } catch (e) {
          last = e;
        } finally {
          if (restarted != null) {
            restarted.client.close();
            await restarted.wire.close();
          }
        }
      }
      if (!ready)
        throw StateError('Failed to verify the restarted image: $last');
    }
    if (transport == transports.last && args.contains('--forget')) {
      bench = await connect();
      try {
        await bench.resume(root);
        await bench.command(p.encodeAction(p.CommandId.forgetPeer));
        stdout.writeln('Authenticated forget acknowledged.');
      } finally {
        bench.client.close();
        await bench.wire.close();
      }
      bench = await connect();
      try {
        await bench.send(bench.client.startSession(root));
        final record = await bench.wire.receive().timeout(deadline);
        if (hex(record) != 'af03')
          throw StateError('Forgotten key was not rejected as unknown');
        stdout.writeln('Forgotten credential rejected.');
      } finally {
        bench.client.close();
        await bench.wire.close();
      }
    }
  }
}
