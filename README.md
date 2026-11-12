# Save Your Old iMac — Turn It into a Monitor

I wanted to use my 2013 iMac as a second screen for my MacBook. This
fork collects my changes and tests for an existing Swift display
streaming app, based on [siavosh87's Luna](https://github.com/siavosh87/luna-display).

The MacBook creates an extra desktop and sends its picture over the local
network. The iMac runs a receiver to display it. Both Macs need to be
running; this does not turn the iMac's port into a video input.

**Status:** the sender and receiver pass local tests on an Apple Silicon
MacBook, including capture, streaming and disconnect cleanup. Testing on
the 2013 iMac over Thunderbolt is still pending. See [test results](TESTING.md)
for the setup and measurement limits.

## Requirements

- **Sender** — macOS 13 or newer, with ScreenCaptureKit and VideoToolbox H.264
  encoding support.
- **Receiver** — the Intel build targets macOS 10.15 Catalina and newer.
  The universal app also contains an Apple Silicon build. The Catalina
  target has been checked in the binary, but not yet tested on the iMac.
- Both Macs need a route to each other over a trusted local network. The
  stream uses TCP without TLS or peer authentication.

## Build

On a Mac with Xcode or the Command Line Tools and Swift 5.9 or newer, run:

```sh
LUNA_ADHOC=1 LUNA_NO_NOTARIZE=1 ./make-apps.sh
```

This builds `dist/LunaSender.app` and `dist/LunaReceiver.app`, with both
`arm64` and `x86_64` slices. The command signs both apps ad hoc and skips
Apple notarization. If SwiftPM fails, the script falls back to
`build-swiftc.sh`. Set `LUNA_USE_SWIFTC=1` to select that path directly.

## Connect

1. Open `LunaReceiver.app` on the Mac you want to use as a monitor. The
   waiting screen shows its address.
2. Open `LunaSender.app` on the Mac you want to extend. In the ☾ menu, pick
   your receiver under **Receivers on network** or use **Connect to
   Address…** with the receiver's hostname and port. The receiver prefers
   TCP port `52525` and can show another port if that one is in use.
3. If macOS prompts the sender for Screen Recording access, capture requires
   that permission. Reconnect after granting it.

Bonjour discovers receivers. In **Automatic** mode the sender tries a
wired route first when it can resolve the endpoint and falls back to
system routing. **Network Interface** lets you choose a specific interface
and shows an error if it cannot reach the receiver. A wired connection
uses Ethernet or Thunderbolt Bridge as a network link. The sender menu
shows the interface used for an established connection when macOS reports it.

Wi-Fi and Thunderbolt Bridge can both provide the local network connection.
For the intended M2 MacBook Air to 2013 iMac setup, the Thunderbolt path
uses an Apple Thunderbolt 3-to-2 adapter and a Thunderbolt cable. A Mini
DisplayPort cable with the same connector shape cannot create that network
link. This two-Mac Thunderbolt setup has not yet been validated here.

The receiver starts fullscreen. Press **⌘⇧F** to toggle windowed mode.
**Esc** returns from windowed mode to fullscreen and quits from fullscreen.

## Display modes

Choose **Display Mode** from the sender's ☾ menu before connecting.

| Preset | Virtual display pixels | H.264 stream pixels | Target bitrate |
| --- | ---: | ---: | ---: |
| 2560×1440 non-Retina (default) | 2560×1440 | 2560×1440 | 40 Mb/s |
| Retina 4K | 3840×2160 | 3840×2160 | 70 Mb/s |
| Retina 5K scaled | 5120×2880 | 3840×2160 | 70 Mb/s |

The sender requests 60 fps. Retina 5K scaled renders a HiDPI desktop with
a 2560×1440-point workspace and sends a 4K stream. The sender uses the
private CoreGraphics `CGVirtualDisplay` API to create the display,
ScreenCaptureKit to capture it, and VideoToolbox to encode H.264. The
receiver passes compressed samples to `AVSampleBufferDisplayLayer` for
decoding and presentation.

## Local checks

```sh
./build-swiftc.sh
./Tests/run-fuzz.sh
python3 Tests/receiver-loopback.py
./.build-swiftc/universal/LunaSender --selftest
```

The receiver test uses `127.0.0.1:52525` and exercises stream framing and
reconnect. Make sure that port is free before running it. The sender
self-test checks creation and removal of all three display presets.
Both checks run without Screen Recording permission.

## License status

This is a GitHub fork of the upstream project. No open-source license was
found in the upstream repository at the revision used here. This fork does
not add a license for the upstream code or grant additional reuse rights.
Public access to source code is not the same as an open-source license.

## Credits

This work is based on the Luna project by GitHub user `siavosh87`. The
original author credits Claude Code for help designing, writing, and
debugging the initial app.
[Original Luna project](https://github.com/siavosh87/luna-display)

## Changes in this version

- Fixed connection cleanup and capture startup handling, and added checks
  for invalid video data before passing it to the display layer.
- Made interface selection stricter and improved reporting of the network
  route used by an established connection.
- Reduced buffer copying when parsing batches of messages, added optional
  latency traces, and made the display self-test check all three presets.
- Changed packaging to build local apps without replacing installed copies
  or resetting Screen Recording permissions.

These changes have passed local tests on the MacBook. Testing on the target
iMac and its Thunderbolt connection is still pending.
