# Verification: Betelgeuse 0.7.0

The 0.6.0 baseline passed all four jobs in
[run 6](https://github.com/Arthuralend/Betelgeuse/actions/runs/45786601051).
The initial 0.7.0 core passed Linux and macOS jobs in
[run 7](https://github.com/Arthuralend/Betelgeuse/actions/runs/45799194602),
including the new two-node and relay exchange test.

| Check | Status |
|---|---|
| Cargo unit tests, CLI, DHT PUT/GET, QR, text ACK, Circuit Relay v2 | PASS (run 7) |
| File offer/accept, chunk transfer with SHA-256, authenticated signaling | PASS (run 7) |
| Final 0.7.0 mobile builds | See latest GitHub Actions run |
| Actual WebRTC audio/video with physical iPhone and Android on different mobile networks | Not yet tested |

The core integration test exercises actual independent libp2p nodes with
synthetic data. It is not an audio/video media test and does not simulate all
cellular NAT/CGNAT behavior. No mandatory WebRTC server is configured.

GitHub produces unsigned mobile artifacts; do not store signing keys in the
repository. See [QUICKSTART-RU.md](QUICKSTART-RU.md) for physical testing.
