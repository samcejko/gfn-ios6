# Changelog

## 0.1.0 (2026-10-04)

First version. Streams real games on an iPad 2 (iOS 6.1.3), verified with Fortnite: video, audio and a touch
gamepad all working. Default stream is 30 fps, which the iPad 2's hardware decoder holds smoothly.

- NVIDIA sign-in with a device code (QR code and link), tokens kept in the keychain and refreshed
- Library and catalog with search, box art and game details
- CloudMatch sessions: queue position, estimates, sponsor breaks, cleanup of sessions left open
- WebRTC stream built from scratch on mbedTLS: ICE, DTLS-SRTP, RTP/RTCP (NACK, PLI, REMB), SCTP data channels
- Hardware H.264 decoding through VideoToolbox, OpenGL ES presentation, Opus audio with redundancy
- On-screen gamepad, mouse mode, keyboard; statistics overlay; session time warnings
- Settings: resolution, frame rate, bitrate, server region (with latency), game language, theme
