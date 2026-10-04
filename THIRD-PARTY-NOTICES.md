# Third-party notices

GFN6 is an independent, unofficial client. It is not affiliated with, endorsed by or associated with NVIDIA
Corporation. GeForce NOW, GeForce and NVIDIA are trademarks of NVIDIA Corporation. The app talks to NVIDIA's
services (login.nvidia.com, pcs.geforcenow.com, games.geforce.com, mes.geforcenow.com, the CloudMatch zones at
nvidiagrid.net and the game seats' signaling servers) with the user's own account; using an unofficial client may be
against NVIDIA's terms of service, which is the user's call.

The GeForce NOW protocol knowledge (sign-in flow, catalog queries, CloudMatch requests, NVST signaling, the SDP
parameter blob and the input channel format) was learned from the open-source OpenNOW family of clients:
[OpenNOW](https://github.com/OpenCloudGaming/OpenNOW) (MIT), [OpenNOW Vita](https://github.com/OpenCloudGaming/OpenNOW-vita)
(MPL-2.0) and [CloudNow](https://github.com/owenselles/CloudNow) (MIT). No code was copied from them; the formats
they document were reimplemented in Objective-C and C.

The private VideoToolbox entry points of iOS 4-7 were known from the XBMC/Kodi project's VideoToolbox decoder
(GPL-2.0); only the function names and signatures are used here, resolved at run time.

## Software

- **Mbed TLS 3.6** - Apache License 2.0. TLS 1.2 for HTTPS and WebSockets, DTLS 1.2 with the use_srtp extension,
  AES-CTR and HMAC for SRTP, the self-signed certificate. https://github.com/Mbed-TLS/mbedtls
- **Opus 1.4** - BSD 3-clause (Xiph.Org Foundation and others). Audio decoding. https://opus-codec.org
- **QR Code generator library (nayuki)** - MIT. The sign-in QR code. https://github.com/nayuki/QR-Code-generator
- **Mozilla CA certificate bundle** (curl.se/ca) - MPL-2.0. The roots the TLS connections are checked against.
- **Theos** - the build system; not shipped in the app.

The license texts of the shipped libraries are included in the app bundle (Settings - Open-source licenses).
