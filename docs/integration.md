# Integrating the shared authority

## Current consumer layout

From the protocol repository root, regenerate, synchronize and verify both consumers:

~~~sh
dart tool/generate.dart
dart tool/sync_consumers.dart firmware ../SmartSpin2k
dart tool/sync_consumers.dart app ../SS2kConfigApp
dart tool/sync_consumers.dart firmware ../SmartSpin2k --check
dart tool/sync_consumers.dart app ../SS2kConfigApp --check
~~~

The firmware compiles the snapshot in lib/SS2kProtocol. The Flutter app uses its in-repository path dependency packages/ss2k_protocol. Each checkout therefore builds independently. The paths passed to the sync tool only identify where to update the two snapshots. The following integration notes also cover alternative Git distribution setups.

## Firmware

1. Add this repository as a pinned dependency (PlatformIO library, Git submodule, or vendored checkout). Use its `c/include` and compile `c/src/ss2k_protocol.c`.
2. Replace the firmware-owned `lib/SS2K/include/CustomCharacteristicProtocol.h` with the generated dependency header by removing the local duplicate from include resolution. The supplied compatibility header preserves `cc_read`, `cc_write`, `cc_success`, `cc_error`, all `BLE_*` names, and `CustomCharacteristicValueFormat`/`customCharacteristicValueFormat` in C and C++. Do not keep two definitions in the same translation unit.
3. Replace the custom service/characteristic UUID literals with `SS2K_SERVICE_UUID` and `SS2K_CHARACTERISTIC_UUID`. Replace snapshot/scan constants and power-table protocol dimensions with the generated values, or add compile-time checks against firmware storage dimensions.
4. Keep firmware setters, command dispatch, event queues, timing, movement limits, save/reboot behavior and transports in firmware. Start with definitions-only adoption to preserve existing validation tolerance. Introduce strict packet validation only after testing older apps, which send extra boolean/action bytes.
5. Build both hardware targets and run the firmware's native protocol tests. Verify requests/replies on BLE at MTU 23 and larger MTUs, including snapshot serialization, scan notifications, large power rows and gear writes; repeat with DirCon.

CMake example:

```cmake
add_subdirectory(external/SS2kProtocol)
target_link_libraries(your_firmware PRIVATE ss2k_protocol)
```

For ESP-IDF, add a component wrapper in the consumer which passes the library's `.c` source and include directory to `idf_component_register`. Standalone hosts can build with the C standard library. The SmartSpin2k build defines `SS2K_PROTOCOL_USE_BYTEUTILS=1` and adds its C-compatible `ByteUtils.h` to the include path. The five public endian helpers then call the firmware's existing `os/endian.h` functions and signed wrappers. This applies to both ESP32 and native ArduinoCompat builds.

## Companion app

1. Add `ss2k_protocol` as a path dependency during migration, then a Git dependency pinned to a reviewed commit/tag after publication.
2. Import `package:ss2k_protocol/ss2k_protocol.dart`. Replace custom UUIDs/IDs and scalar serialization with its constants and codecs. Do not use host-endian typed-list reinterpretation for BLE integers.
3. Replace the protocol portion of `constants.dart` with `createAppDescriptors()`. Convert each descriptor's `settingType` string to the app's existing enum, and retain app-owned display conversions, colors, screens, and mutable state. Snapshot aliases are explicit, including `shifterDir`, `udpLogEnabled`, `hMin`, `hMax`, and `pTab4Pwr`.
4. Route writes by descriptor: actions use `encodeAction`, ordinary scalars/string/bool use `encodeValue`, explicit wire-unit values use `encodeScalarWrite`, tooth arrays use `encodeGearTeeth`, and each power row uses `encodePowerTableRow`. Logging must use boolean writes despite its legacy UI type being `string`. A groupset UI still coordinates the preset and tooth commands.
5. Decode with the pending operation's reply kind. On legacy devices, a notification may complete a shifter write. Pass a decrypted secure notification (`0x81`) with notification context; both codecs preserve its status and reject it in read or write context. Legacy notifications use `0x80`. Secure v1 uses an explicit shifter acknowledgement; snapshots arriving through DirCon notifications still belong to a read transaction. Only interpret error payloads as errors. Clear assembly and pending operations on disconnect/timeouts.
6. Use `SnapshotAssembler` or retain the app's existing assembler with generated constants. The shared `ScanFragment` provides framing validation; keep the existing scan-session reassembler while replacing its duplicated numbers.
7. Run the app's tests, analyzer, BLE and DirCon integration checks. When polling older firmware, preserve the unsupported-command fallback instead of assuming every manifest ID is implemented.

Illustrative app adapter (inside the app, where `SettingType` is defined):

```dart
final descriptors = protocol.createAppDescriptors().map((item) {
  return <String, dynamic>{
    ...item,
    'settingType': SettingType.values.byName(item['settingType'] as String),
  };
}).toList();
```

The adapter intentionally preserves legacy app names such as `BLE_homingMin`; protocol IDs and snapshot keys remain authoritative. Duplicate target-watts descriptors were removed from the imported baseline. The retired update fields remain available for old firmware, discovered-device data starts empty, and the password field starts blank.

## How changes reach both projects

There are two distinct updates: generate the library from JSON, then advance the consumers' dependency revisions.

```text
protocol/ss2k.json
    -> generator + validation + tests
    -> committed C/Dart libraries and protocol reference
    -> published Git commit/tag
    -> consumer dependency update + consumer CI
    -> firmware/app release
```

A local path dependency sees regenerated files immediately on the next build. For reproducible released builds, pin a shared Git commit/tag. Dart's `pubspec.lock` and a Git submodule's recorded commit remain pinned until updated. A floating branch plus a cached lockfile is not automatic propagation.

Use the same published repository URL in both consumers. For a Git-submodule layout such as `external/SS2kProtocol`, the app can use a path dependency to that submodule and firmware can use the same directory in CMake/PlatformIO. This gives both languages the same revision mechanism.

The supplied [consumer workflow example](../examples/update-protocol.yml) can be installed in each consumer once it adopts this submodule layout. A `repository_dispatch` event or manual workflow run advances the submodule to the chosen ref and opens an update PR. It does not merge or deploy it. Configure consumer CI to compile/test the resulting PR. A master release workflow can dispatch that event to each consumer using a GitHub App token with access to both repositories; the master repository's default token alone cannot write another private repository. Repository URLs, app credentials and release policy must be configured at publication time.

Alternative: retain each ecosystem's own Git dependency and have your existing dependency-update tooling open revision updates. In either layout the JSON is edited once, and consumers compile the generated protocol library instead of maintaining their own ID/type tables.

The example requires `SS2K_PROTOCOL_UPDATE_TOKEN`, a fine-grained token with consumer contents/PR write and protocol repository read access, or an installation token injected by a GitHub App token step. This allows consumer CI to run normally; PRs created with the default token can require workflow approval. See [GitHub's token event rules](https://docs.github.com/en/actions/concepts/security/github_token). Dart Git refs and locked revisions are described in [package dependencies](https://dart.dev/tools/pub/dependencies) and [pub get](https://dart.dev/tools/pub/cmd/pub-get).

## Adding or changing a command

1. Choose an unused ID, never a retired ID. Add a complete manifest entry. Set unsupported directions to null, set wire scale explicitly, and add an exact snapshot alias only if the user-config snapshot actually contains it.
2. Add a firmware handler and any required persistence/notification behavior in the firmware repository. The generator only implements the protocol representation.
3. Add app metadata if the generic settings UI should expose the command. Otherwise use the generated ID/descriptor from a specialized screen.
4. Add independent packet fixtures to `test/vectors.json`, then regenerate and run tests. The suite also verifies that a synthetic newly added scalar command appears in both libraries without changing codec code.
5. Compare against the previous manifest with `dart tool/check_compatibility.dart <previous.json>`. CI performs this check for PRs. Existing wire changes fail deliberately; a future incompatible protocol needs a separately reviewed version/negotiation design rather than an accidental reinterpretation of old IDs.
6. Publish the generated commit/tag, update both consumer dependencies, and run their integration tests.

## Source audit

```sh
dart tool/audit_firmware.dart ../SmartSpin2k
```

This optional read-only audit compares all legacy IDs/formats and table dimensions with an unconverted firmware checkout. It does not overwrite the manifest, and it is not a substitute for reviewing handler semantics. Once firmware uses the generated compatibility header directly, this audit against the old header location is no longer applicable.
