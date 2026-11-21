# Paired custom characteristic, version 1

The capability read `01 36` and secure identity/handshake opcodes are available before authentication. All settings, snapshots, logs and firmware-update records require an authenticated session. Other BLE services keep their existing protocols. Both transports use identical application records.

## Discovery and trust

A capability reply is `80 36 01 bits:LE32`. Bit 0 means the WiFi password is write-only. Bit 1 requires this secure protocol. `A0` requests the trainer identity and `A1 || deviceId[8]` returns it. This public, device-stable identifier allows the same pairing to work over BLE or DirCon, including after an IP or device-name change. The identity acquires authenticity only when a stored root verifies the session proof.

Legacy firmware can answer the capability request with an explicit unsupported-command response. A previously paired endpoint must fail closed on timeout, malformed replies, lost features or failed authentication. Clients retain the pairing across these failures. Unrecognized unauthenticated devices can impersonate legacy firmware when no authenticated identifier is available. A BLE address, DNS name or advertised IP is insufficient proof of identity.

## Initial pairing

Each client pairing uses a random 8-byte app ID and its own 32-byte root key. The link initiator sends A2 below. The firmware reserves one pending candidate for the particular live connection and waits for a fresh physical gesture. It requires the buttons to have been released and then held simultaneously. A disconnect, timeout or reboot cancels the pending candidate. A second connection cannot consume or replace it.

| Packet | Direction | Fields |
| --- | --- | --- |
| A2 | app to trainer | app ID (8), ephemeral P-256 public key (65) |
| A3 | trainer to app | ephemeral P-256 public key (65), sent after the hold |
| A4 | app to trainer | first 16 bytes of HMAC-SHA256(root, ASCII `client`) |
| A5 | trainer to app | first 16 bytes of HMAC-SHA256(root, ASCII `device`) after persistent save |

Both ephemeral keys use fresh cryptographic randomness. Public keys are canonical SEC1 uncompressed points (04, 32-byte x, 32-byte y, all integers big endian). Validate the finite point against the P-256 curve and field. P-256 has cofactor one. ECDH yields a fixed-width 32-byte big-endian x coordinate, including leading zeros. The root is HKDF-SHA256 with that coordinate as IKM, SHA256(A2 || A3 || deviceId) as salt, ASCII `SS2K/pair/v1` as info, and output length 32. Include the opcodes in A2 and A3. All labels are literal ASCII without terminators. Secret key bytes never cross the radio.

The app can stage the newly derived root before sending A4, permitting recovery if A5 is lost after the trainer commits. Stage it separately from a prior confirmed root. Key confirmation or a successful resume completes the local commit. A public unknown-key error can prompt explicit physical re-pairing but cannot authorize local deletion or downgrade.

Button confirmation establishes physical presence and limits which pending connection the trainer accepts. With no factory trust anchor or independently compared code, an active intermediary present during the initial exchange can substitute public keys. Subsequent sessions authenticate by proof of possession of the stored root. Pairings persist until authenticated forget or factory reset. Reconnecting neither expires nor rotates stored pairings.

## Resume

| Packet | Direction | Fields |
| --- | --- | --- |
| B0 | app to trainer | app ID (8), fresh random (16) |
| B1 | trainer to app | fresh random (16), server proof (16) |
| B2 | app to trainer | client proof (16) |
| B3 | trainer to app | ready proof (16) |

T = SHA256(deviceId || B0 || trainerRandom). Each proof is the first 16 bytes of HMAC-SHA256(root, label || T) using the ASCII labels `server`, `client` and `ready` respectively. Compare proof bytes in constant time. Every new session uses fresh independent nonces from each endpoint. No data flows before mutual confirmation. State belongs to the specific connection, including handle generation.

Derive 64 bytes using HKDF-SHA256(root, salt=T, info=ASCII `SS2K/session/v1`). Bytes [0,16) are the app transmit AES key, [16,32) the trainer transmit key, [32,40) the app nonce prefix and [40,48) the trainer nonce prefix. The remaining bytes are unused. Erase volatile handshake/session secrets when their lifetime ends. Fresh sessions after disconnect/reboot avoid persistent counter writes.

## Records and transport

A secure record is `D0 || seq:LE32 || ciphertext || tag[8]`. Use AES-128-CCM with a 12-byte nonce consisting of the directional 8-byte prefix and 4-byte little-endian sequence. The five header bytes are the additional authenticated data. The sequence begins at zero in each direction. Advance the send sequence for every encryption and reconnect before wrapping. A receiver accepts only a sequence greater than the last accepted sequence. Verify the tag before updating the counter or releasing plaintext. A failed tag ends the session, limiting forgery attempts per traffic key. Maximum inner payload is 512 bytes, including its operation/status and ID. The secure overhead is 13 bytes.

Requests, command replies and request-bound snapshot chunks keep their inner layouts. Unsolicited changes, logs and scan events carry inner status `81`, which cannot complete a pending command. Request-bound write acknowledgements and snapshot chunks carry `80` on success. Serialize commands per connection because the inner protocol does not carry a transaction ID.

When a complete record exceeds the transport capacity, fragment the assembled record *after* encryption: `F0 || flags || index || fragmentBytes`. Bit 0 marks start, bit 1 marks end, all other bits are zero. Index starts at zero and increments for each fragment. Fragment only complete record bytes, with at most 525 bytes accumulated for a single record per peer. Reject missing, nested, duplicate, interleaved and out-of-order fragments. Reset assembly on disconnect and timeout. At ATT MTU 23 the wire capacity is 20 bytes. BLE secure frames use ordered writes and notifications. DirCon partial writes can return an empty characteristic value. The completed logical reply or delayed pairing offer can arrive via a later notification. Serialize outbound fragments so intervening notification traffic cannot corrupt the assembly.

Public failures use `AF reason:u8`. Reasons are 1 invalid, 2 busy, 3 unknown key, 4 timeout and 5 storage/full. These messages cannot erase durable keys.

## Forget, reset and updates

Authenticated `02 37` deletes the requesting app pairing. The trainer seals `80 37` using its still-live session and invalidates all sessions for that pairing. Remove the local root following the authenticated acknowledgement. A factory reset removes all persisted pairings and settings. Firmware and app need a recovery path for an acknowledgement lost after the durable operation.

Firmware streaming uses encrypted `02 38 op fields` only. Begin (0) carries a nonzero image size LE32 and the 32-byte SHA-256 image digest. Chunk (1) carries offset LE32 and one or more image bytes. Finish (2) and abort (3) carry no other fields. Replies carry `80/FF 38 op nextOffset:LE32`. Firmware accepts one authenticated owner, writes exact consecutive offsets to the inactive application partition, checks size and digest before activating, and abandons partial updates on disconnect. The digest detects stream corruption, while firmware publisher authentication depends on the platform's image-signing policy.

## Independent checks and hardware smoke

`dart test/run.dart` checks the C/C++ and Dart codec fixtures. `dart test/secure_test.dart` runs the production Dart client against an independent Python cryptography reference with fresh client keys each time. Install the Python cryptography package before running the latter. The checked-in secure vector is reproducible with the reference peer's public test keys.

`dart tool/secure_bench.dart --help` lists the live bench command options. The runner uses the production Dart SecureClient including reassembly, prints no secrets, retains its test pairing in memory across transports, and supports an authenticated forget at the end. A BLE helper writes READY after subscription, then exchanges one characteristic packet per newline as hex over stdout/stdin. Its stderr is for diagnostics. No button simulation is part of the protocol package.
