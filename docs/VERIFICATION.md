# Verification: Betelgeuse 0.8.0

Automated checks are available in GitHub Actions. 0.7.1 was compiled
and signed; user confirmed that Rust started on both physical iPhones.
0.7.1 then produced EADDRINUSE on attempting TCP dial. 0.8.0 explicitly
allocates a new local port for ordinary known-peer dials, configures
trusted automatic bootstrap with persistent settings, and adds consented
pairing.

New acceptance test: tests/auto_pair_nodes.py (trusted relay reservation,
signed profile & route publication, rejection before consent, mutual
contact storage and delivery after client restart).
Existing tests cover actual signed DHT, QR, relay transport, files, and
synthetic WebRTC media. The test phones must still validate discovery,
the new TCP connection, cellular handoff, and legacy iOS audio.
