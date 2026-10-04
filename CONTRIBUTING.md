# Contributing

## Building without a Mac

Every push builds on GitHub Actions (`.github/workflows/build.yml`): Theos, the iOS 9.3 SDK from theos/sdks, a
Linux clang toolchain, Mbed TLS 3.6, libopus 1.4 and the qrcodegen C encoder are fetched there. The result is an
IPA and a DEB in the `GFN6-packages` artifact. Compile errors show up in the `build-log` artifact and in the job log.

`tools/gh-push.ps1 -Message "..."` pushes the working tree through the GitHub API (no git needed),
`tools/gh-build.ps1 -Download -HeadSha <sha>` waits for the build and downloads the packages,
`. .\tools\ipad.ps1; Install-IPadPackage -IpaPath ...` installs over SSH, `Enable-GFN6Debug` turns the `gfn6:`
debug commands on, `Invoke-GFN6 'gfn6:selftest'` runs the protocol self tests on the device, `Get-GFN6Log` reads
the app's log lines, `Get-IPadScreen -OutFile x.png -Real` grabs the screen. `tools/local.json` (ignored by the
push script) holds the repository, token and the device address.

## Ground rules

- iOS 6.0 is the deployment target, armv7 only. Anything newer than iOS 6 is a compile error (`-Wunguarded-availability`
  and the pragma in `GFCommon.h`). No storyboards, no auto layout, UI in code.
- ARC in Objective-C; the transport is plain C with no allocation on the packet path where it can be avoided.
- All networking goes through the `GFTLSSocket`/`GFHTTPRequest`/`GFWebSocket` stack (iOS 6 cannot talk TLS 1.2
  to modern servers). Never `NSURLConnection`/`NSURLSession`.
- Text shown to the user goes through `L()` with the English text as the key; `Resources/cs.lproj` has the Czech.
  `tools/check-strings.ps1` lists what is missing.
- No secrets in the repository. The app has no client secret at all; user tokens live in the keychain.
- Keep the protocol pieces honest with their self tests (`gfn6:selftest`): SRTP key derivation (RFC 3711 vectors),
  CRC32c, STUN integrity, SPS parsing, certificate creation, VideoToolbox availability.

## In the pull request

Say what you tested on a real device (model, iOS version) and attach a screenshot when the UI changed.
