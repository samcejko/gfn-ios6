# GFN6 - GeForce NOW on iOS 6

An unofficial GeForce NOW client for jailbroken iOS 6.x devices (iPad 2 and up, iPhone 4S and up). It signs in to
your NVIDIA account, shows your game library, waits in NVIDIA's queue and streams the game over a WebRTC
connection built from scratch for a 2012 phone: hardware H.264 decoding, Opus audio, a touch gamepad, mouse mode
and a keyboard.

GFN6 is not affiliated with, endorsed by or associated with NVIDIA or GeForce NOW. You need your own GeForce NOW
account. The protocol work follows the open [OpenNOW](https://github.com/OpenCloudGaming/OpenNOW) family of
clients (notably [OpenNOW Vita](https://github.com/OpenCloudGaming/OpenNOW-vita), which proved it on a console of
similar power).

## Features

- Sign in with a code on another device (the OAuth device flow; no password ever touches the app)
- Your library and the full catalog with search, box art, game details
- Queue with position and estimate, free-tier sponsor breaks acknowledged, sessions left open get cleaned up
- Stream: WebRTC (ICE, DTLS-SRTP, RTP/RTCP with NACK/PLI/REMB, SCTP data channels) over the app's own mbedTLS stack
- Video: H.264 through the hardware decoder, drawn with OpenGL ES; resolution, frame rate and bitrate are yours to pick
- Audio: Opus with NVIDIA's redundancy for lost packets, low-latency output
- Controls: on-screen Xbox-style gamepad, trackpad-like mouse mode, the iOS keyboard with Esc/Tab/Enter/arrows
- Server region picker with latency, game language, dark and light theme, Czech and English

## How it works

The app talks to the same services NVIDIA's own clients use: `login.nvidia.com` for the sign-in code and tokens,
`games.geforce.com/graphql` for the catalog, CloudMatch (`*.cloudmatchbeta.nvidiagrid.net`) for sessions and the
game seat's own WebSocket for signaling. iOS 6 cannot negotiate TLS with any of them, so everything goes through the
bundled Mbed TLS: HTTPS, the WebSocket, and the DTLS of the media transport.

Video arrives as RTP, is decrypted (SRTP), reassembled into H.264 access units and decoded by VideoToolbox, which
is a private framework on iOS 6 (public from iOS 8 with the same functions). The decoded pictures go to the screen
through the OpenGL ES texture cache without a copy. Input travels back over an SCTP data channel in NVIDIA's binary
input format.

## Installing on the device

Install the **DEB** (`dpkg -i`, then `su mobile -c uicache`). It has to be the DEB, not the IPA: the DEB installs
into `/Applications`, where the app may open the hardware H.264 decoder. An IPA installed into the app container is
sandboxed away from the decoder (`sandboxd` denies `iokit-open AppleVXD390UserClient`) and shows a black screen,
so the IPA is only useful for the non-video screens. Do not keep both installed at once.

## Building

There is no Mac involved: GitHub Actions builds the app with Theos, the iOS 9.3 SDK and a Linux clang toolchain
(`.github/workflows/build.yml`), fetching Mbed TLS, libopus and the QR encoder on the fly. Push a commit and download
the `GFN6-packages` artifact. The scripts in `tools/` push through the GitHub API, wait for the build, install over
SSH and drive the app for screenshots (see `CONTRIBUTING.md`).

## Project layout

```
src/GFN      NVIDIA services: sign-in (GFAuth), catalog (GFAPI), sessions (GFCloudMatch), signaling, SDP, input protocol
src/RTC      the media transport in C: STUN, DTLS (mbedTLS), SRTP, RTP/H.264, RTCP, SCTP + data channels; GFPeer ties them together
src/Media    hardware H.264 decoder, OpenGL ES video view, Opus audio player
src/Net      TLS socket, HTTP client, WebSocket, image loader (shared with the other iOS 6 apps of this family)
src/UI       library grid, game page, queue, stream screen, touch gamepad, settings, sign-in
tools        push/build/release/device scripts, icon, asset generator
vendor       mbedTLS configuration and glue (the libraries themselves are fetched by CI)
```

## Privacy

The app stores your NVIDIA tokens in the keychain of the device and sends them only to NVIDIA's services. There is
no telemetry. The device id NVIDIA sees is a random number made once per installation.

## License

MIT, see `LICENSE`. Third-party notices in `THIRD-PARTY-NOTICES.md`.
