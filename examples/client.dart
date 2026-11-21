import '../lib/ss2k_protocol.dart';

void main() {
  final request = encodeValue(CommandId.simulatedSpeed, 26.3);
  print(request); // [2, 6, 7, 1]
  final reply = decodeResponse([128, 6, 7, 1], kind: ReplyKind.write);
  print(reply.value); // 26.3
  print(encodeAction(CommandId.saveToLittleFS)); // [2, 24]
}
