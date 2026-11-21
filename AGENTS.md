# SS2kProtocol

The authority is `protocol/ss2k.json`. Edit that file, then run `dart tool/generate.dart`. Never edit generated headers, descriptor tables, Dart definitions, package manifests or `docs/protocol.md` directly.

The handwritten codecs are `c/src/ss2k_protocol.c` and `lib/ss2k_protocol.dart`. Keep C99 portable, allocation-free, length-checked and independent of Arduino/ESP-IDF; preserve C++ inclusion compatibility. Packet handling must distinguish read replies, write replies and notifications, especially for BLE logging.

Validate with `dart tool/generate.dart --check`, `dart --suppress-analytics analyze lib tool test examples`, and `dart test/run.dart` (requires GCC/G++). The tests compile C/C++, run shared packet fixtures and check generation/compatibility. Add independent wire vectors for protocol changes. On this Windows machine Dart is available at `../flutter/bin/cache/dart-sdk/bin/dart.exe`.

Do not reuse retired ID 0x33 or silently alter an existing wire contract. App presentation defaults are not firmware defaults. Firmware handlers and transport/session behavior belong to consumers. `tool/audit_firmware.dart` is read-only; never reimport sibling repositories over the master. Publishing and consumer adoption are separate steps; do not claim they happened merely because local libraries were generated.

Secure v1 uses the generated constants, the Dart client in lib/secure.dart, and C framing in c/include/ss2k_secure.h. Run dart test/secure_test.dart with Python cryptography installed for independent interoperability checks. After shared-code changes, refresh both vendored subsets using tool/sync_consumers.dart and verify with --check. Live bench clients use ephemeral in-memory credentials; use --forget for the one-companion check. The multi-companion tool verifies and revokes both test pairings.
