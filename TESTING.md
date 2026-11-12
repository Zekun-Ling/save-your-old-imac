# Local test results

Test date: November 12, 2026.

The sender and receiver ran on the same MacBook Air over `127.0.0.1`.
The receiver was headless. These results do not measure the target iMac,
Wi-Fi, Thunderbolt Bridge, or visible screen response.

## Setup

| Item | Configuration |
| --- | --- |
| Test computer | MacBook Air, Apple M2, 8 GB RAM |
| System | macOS 15.3.2 |
| Virtual display and video stream | 2560 × 1440 |
| Requested capture rate | 60 fps; presented frame rate was not measured |
| Target video bitrate | 40 Mb/s, H.264 |
| Network | Loopback (`lo0`), both processes on the same computer |
| Receiver | Headless, listening only on `127.0.0.1:52525` |

The intended second computer is a Late 2013 Intel iMac running macOS
Catalina. That machine's playback and Thunderbolt connection remain to be
tested. The Intel receiver binary's minimum OS version is macOS 10.15;
this is a build check, not proof of runtime compatibility.

## Checks completed

- Both apps built with `arm64` and `x86_64` slices and passed strict ad hoc
  signature checks. The builds were not notarized.
- All three display presets registered with the expected dimensions and
  were removed after the self-test.
- Parser fuzzing and tests for invalid streams, timeouts and reconnects
  passed.
- The packaged sender captured a real virtual display, streamed frames to
  the receiver, and removed the display on disconnect.

These checks cover the code snapshot validated before the documentation
and publication changes. No application source was changed for publication.

## Timing sample

Eight matched trace samples from a run lasting a few seconds gave:

| Interval | Median | Maximum |
| --- | ---: | ---: |
| Capture submission to receiver sample enqueue | 10.56 ms | 55.03 ms |
| Encoding stage | 9.89 ms | Not summarized |
| Send submission to receiver parsing | 0.27 ms | 42.88 ms |

These are diagnostic samples, not a sustained performance benchmark. The
first interval excludes input-to-capture time, decoder output and panel
refresh. It must not be described as mouse latency, end-to-end display
latency, or a Wi-Fi/Thunderbolt result. Stage medians do not necessarily add
up to the total median.

## Reproducing the basic checks

From the repository root:

```sh
./build-swiftc.sh
./Tests/run-fuzz.sh
./.build-swiftc/universal/LunaSender --selftest
python3 Tests/receiver-loopback.py
```

The receiver test needs port `52525` to be free. The sender self-test
creates temporary displays. A full capture test also needs Screen
Recording permission for the sender.

Before reporting two-computer performance, check the actual interface in
the sender's connection status, confirm visible playback on the iMac,
and test reconnect, dragging windows and scrolling. Measure visible
input-to-screen response separately from the internal trace timestamps.
