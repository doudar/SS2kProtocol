# SS2kProtocol

One master JSON definition for the SmartSpin2k custom BLE/DirCon characteristic, with a generated reference, an allocation-free **C99 library**, and a **pure Dart package** usable from Flutter.

Version 0.2 adds physical pairing, encrypted sessions over BLE and DirCon, authenticated firmware streaming, and a portable Dart client. See [the wire protocol and trust model](docs/secure.md). Synchronize with the consumer source directories using the sync_consumers tool; its --check flag detects drift.

The original 0.1 manifest covered **52 commands**, IDs `0x01`–`0x35` excluding retired `0x33`, using the local firmware and app implementations inspected on November 8, 2026. This is a source-reviewed baseline, not a claim that every released firmware has these capabilities. See [provenance](protocol/provenance.json) for source revisions and working-file hashes.

| File | Purpose |
|---|---|
| [protocol/ss2k.json](protocol/ss2k.json) | Authority for IDs, UUIDs, direction-specific payloads, scaling, snapshot aliases, reserved IDs, protocol notes, and app presentation metadata |
| [protocol/schema.json](protocol/schema.json) | Machine-readable schema; generator also checks cross-field constraints |
| [docs/protocol.md](docs/protocol.md) | Generated master protocol reference |
| [c/include/ss2k_protocol.h](c/include/ss2k_protocol.h) | Public C99 codec API |
| [lib/ss2k_protocol.dart](lib/ss2k_protocol.dart) | Dart codec API and generated descriptors |
| [docs/integration.md](docs/integration.md) | Adoption and dependency-update workflow for both projects |

## Update the authority

Requires Dart 3.3+; tests additionally require GCC and G++. Run dart pub get to resolve PointyCastle for the secure client. Secure interoperability tests also require Python and the cryptography package. CI uses Dart 3.12.2, matching the locally tested SDK.

```sh
dart tool/generate.dart
dart tool/generate.dart --check
dart --suppress-analytics analyze lib tool test examples
dart test/run.dart
dart test/secure_test.dart
```

Edit `protocol/ss2k.json`, increment its library version, regenerate, and commit the manifest with its generated files. The generator runs schema validation and produces the C definitions/table, optional legacy firmware header, Dart definitions/app descriptors, Markdown reference, and package versions. Generation is deterministic and does not access sibling repositories or the network.

Adding a command with an existing payload format requires only a manifest entry to update IDs, descriptors, validation, codecs, and documentation. A genuinely new payload grammar requires runtime codec support and a schema/generator change too. Firmware handlers, persistence, side effects, app screens, and transport/session management remain in their respective projects; a descriptor cannot implement those behaviors.

The `Regenerate protocol libraries` workflow regenerates and tests artifacts after a manifest change on `main`, or on manual dispatch, then commits changes using the repository token. It needs repository contents-write permission and branch rules that permit that bot commit. PRs must already contain current generated output; CI rejects drift and wire-incompatible edits. A protected branch can use the manual local generation workflow instead.

## C99

Compile `c/src/ss2k_protocol.c` and add `c/include` to include paths, use the root CMake target `ss2k_protocol`, or consume the supplied PlatformIO `library.json`. No Arduino, C++ runtime, platform SDK, heap allocation, or JSON parsing is involved.

```c
#include "ss2k_protocol.h"

uint8_t packet[4];
size_t size;
ss2k_result result = ss2k_encode_scalar_write(
    SS2K_ID_SIMULATED_SPEED, 263, packet, sizeof packet, &size);
/* Check result == SS2K_OK, then send: 02 06 07 01 (26.3 km/h). */
```

The C API uses raw wire integers and exposes each command's scale. Encoders take caller-owned buffers and leave them unchanged on failure. Decoders return views into the input buffer; keep that buffer alive while using the view. The 52-entry descriptor table occupies 520 bytes on the tested host ABI, with at most six binary-search iterations. Target flash/stack usage and cycle counts depend on compiler and architecture and have not been measured on ESP32.

## Dart / Flutter

For local adoption, add this package using a path dependency:

```yaml
dependencies:
  ss2k_protocol:
    path: ../SS2kProtocol
```

```dart
import 'package:ss2k_protocol/ss2k_protocol.dart';

final request = encodeValue(CommandId.simulatedSpeed, 26.3); // 02 06 07 01
final reply = decodeResponse([0x80, 0x06, 0x07, 0x01], kind: ReplyKind.write);
final speed = reply.value; // 26.3
```

Use `encodeScalarWrite` for explicit raw integers; `encodeValue` scales engineering values and rounds to the nearest wire unit, ties away from zero. Reply context is required because logging reads return text while logging write acknowledgements return a boolean. Check `isError` and correlate the ID with the outstanding command before consuming a response. `SnapshotAssembler` supports bounded, out-of-order reassembly. `ScanFragment` parses individual scan packets; the consumer owns scan-session/fragment assembly and timeouts.

## Compatibility and limits

- Existing IDs, signedness, little-endian encoding and scaling are preserved. `0x33` is permanently reserved. Manifest versioning does not introduce a new on-wire handshake.
- Client encoders emit canonical packet lengths and boolean values. Existing firmware accepts some padded/noncanonical requests; `ss2k_validate_request` is deliberately stricter and must not replace the firmware's legacy request handling without a migration decision. A two-byte boolean write echo can be accepted explicitly by response decoders.
- Integer bounds describe wire representation. Firmware setters still own domain limits and supported preset values. Gear arrays and row indexes receive structural validation to prevent known malformed requests.
- String payloads use UTF-8 at the Dart API and byte views in C. Embedded NUL is rejected for writes. A device may return non-UTF-8 legacy text; Dart's text accessor reports that as an error.
- App descriptors are presentation metadata, not firmware defaults. Flutter colors/enums, live mutable values and per-device state belong in the app adapter.
- Host tests cover both codecs and source-format compatibility. BLE/DirCon transport behavior and live firmware integration have not been hardware-tested here.

The app and firmware feature branches consume generated snapshots of this package. Run dart tool/sync_consumers.dart with app ../SS2kConfigApp or firmware ../SmartSpin2k to update them. Both modes accept --check.

Licensed GPL-2.0-only, consistent with the inspected SmartSpin2k and companion app sources. See [LICENSE](LICENSE).
