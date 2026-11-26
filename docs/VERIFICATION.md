# Verification: Betelgeuse 0.7.0

Sources and checks:
- [Run 7: initial Rust exchange](https://github.com/Arthuralend/Betelgeuse/actions/runs/45799194602)
- [Run 8: final Rust core, CLI and native compilation](https://github.com/Arthuralend/Betelgeuse/actions/runs/45802990883)
- [Run 9: mobile package publication and WebRTC media](https://github.com/Arthuralend/Betelgeuse/actions/runs/45803693598)

| Check | Result |
|---|---|
| Cargo unit tests, Linux CLI, DHT PUT/GET, QR, text ACK and Circuit Relay v2 | PASS |
| macOS CLI build and local test | PASS (run 8 and local Mac) |
| 2 MiB file, transfer acceptance, full byte and SHA-256 verification, direct connection | PASS |
| Same file transferred through actual Circuit Relay v2 | PASS |
| Call signaling on authenticated Rust peers | PASS |
| Bidirectional WebRTC synthetic audio and decoded video, actual SDP/ICE over Rust | PASS (run 9) |
| Android ARM64/x86_64 APK with native Rust and WebRTC | Build and local signature verification PASS |
| iOS ARM64 IPA with embedded WebRTC, device/simulator ARM64 Rust XCFramework | Build and local development signature verification PASS |
| Physical iPhone and Android across cellular operators | NOT TESTED |

Run 9's media test launched two independent Rust CLI peers and two
WebRTC connections in Chrome using synthetic cameras and microphones.
Both endpoints received 23 audio packets and 12 video packets;
one decoded 8 video frames and the other 7. This demonstrates the
signaling and transport architecture, not the mobile camera UI or CGNAT.
The final core was also tested locally on macOS: direct and relayed file
transfer passed, and error events did not terminate the engine.

The Android APK was signed locally with the existing beta signing key
and the signing certificate matches 0.6.0. The iPhone IPA was signed
locally with a development certificate and provisioning profile; the
embedded WebRTC framework and application passed strict codesign
verification. Development IPA installation is limited by provisioning.
No private signing material is stored in GitHub.

No mandatory central server is built in. Direct WebRTC media uses ICE;
some separate mobile networks require user-configured TURN. The libp2p
relay transports signaling and files, not WebRTC media. Physical end-to-end
verification is outstanding because no test phones were accessible.

See [QUICKSTART-RU.md](QUICKSTART-RU.md).
