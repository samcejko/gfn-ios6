# Changelog

## 0.1.0 (unreleased)

First version.

- NVIDIA sign-in with a device code (QR code and link), tokens kept in the keychain and refreshed
- Library and catalog with search, box art and game details
- CloudMatch sessions: queue position, estimates, sponsor breaks, cleanup of sessions left open
- WebRTC stream built from scratch on mbedTLS: ICE, DTLS-SRTP, RTP/RTCP (NACK, PLI, REMB), SCTP data channels
- Hardware H.264 decoding through VideoToolbox, OpenGL ES presentation, Opus audio with redundancy
- On-screen gamepad, mouse mode, keyboard; statistics overlay; session time warnings
- Settings: resolution, frame rate, bitrate, server region (with latency), game language, theme
