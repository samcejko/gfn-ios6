# Changelog

## 0.2.0 (2026-10-14)

- A second build for 64-bit devices with iOS 14–17 (iPhone X and newer), from the same source tree: the `.deb` with
  `iphoneos-arm64` in its name for rootless jailbreaks (palera1n, Dopamine; it installs into `/var/jb`) and
  `GFN6-<version>-arm64.ipa` for TrollStore, where the public VideoToolbox decodes inside the sandbox too. Not tried
  on a device yet.
- 64-bit fixes: the VideoToolbox decode call passed its last argument as a number instead of a pointer; the audio
  ring between the decoder and the output has memory barriers; the RTCP sender-report clock is 64-bit (it wrapped
  after 71 minutes of uptime). A session iOS 8 and newer invalidate in the background is rebuilt instead of freezing.
- On iOS 7 and newer the app draws the glossy iOS 6 bars, the black glass tab bar, bordered bar buttons and rounded
  grouped tables itself, stays in light mode and opens its screens full screen. The touch gamepad and the stream's
  labels keep clear of the notch and the home indicator; an edge swipe goes to the game first.
- The 32-bit build gets the same look on devices with iOS 7–10.

## 0.1.1 (2026-10-14)

- Settings → About has a "Support the development" row that opens the author's Ko-fi page. The app stays free.
- GFN6 is in the repository `http://repo.samcejko.eu/` now (Cydia, Sileo, Zebra, Installer): add it as a source to get updates.

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
