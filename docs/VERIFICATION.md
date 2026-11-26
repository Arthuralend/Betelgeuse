# Verification: Betelgeuse 0.6.0

All four jobs in the final build completed successfully:
[GitHub Actions run 6](https://github.com/Arthuralend/Betelgeuse/actions/runs/45786601051).

| Check | Result |
|---|---|
| Linux Cargo unit tests and release CLI | PASS |
| macOS ARM64 CLI and two-node integration | PASS |
| Persistent Ed25519 identity, verification of public key and signature, expiration and rollback checks | PASS (unit / integration tests) |
| Real DHT PUT/GET across two independent processes, QR decoding and message ACK | PASS |
| Real Circuit Relay v2 reservation and message ACK across three processes | PASS |
| Native Rust engine start/status/shutdown | PASS |
| Android ARM64 and x86_64 JNI libraries and APK | Build PASS |
| iOS ARM64 IPA and device/simulator ARM64 XCFramework | Build PASS |

The Linux job actually decodes the generated SVG QR with zbar, and the
two-node test restarts a node before retrieving a record from its peer.
The relay test confirms a relayed connection and message acknowledgement.
The committed Cargo.lock was extracted from the successful Linux build.

The Android APK was signed locally with the existing application signing key;
the certificate matches 0.3.0. The iPhone IPA was signed locally with a valid
development certificate and provisioning profile. Both local signatures were
checked successfully. Private signing material is never committed.

The platform binaries have not been installed and exercised end-to-end on
physical phones in different networks. Two-peer TCP and relay behavior was
tested with real CLI processes; successful DCUtR traversals on arbitrary
mobile CGNAT networks, WebRTC/Opus, file and video transport over the new Rust
mode, automatic DHT republishing, mobile QR camera scanning and 0.3.0 identity
migration remain to be verified or implemented. The old compatible mode is
retained to preserve existing local data.

See [QUICKSTART-RU.md](QUICKSTART-RU.md).
