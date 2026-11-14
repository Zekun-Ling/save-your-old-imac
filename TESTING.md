# Test results

## Thunderbolt Bridge on a 2013 iMac

On November 14, 2026, an M2 MacBook Air streamed its extended desktop to a
2013 iMac over the Thunderbolt Bridge interface. The sender used 2560 × 1440
H.264 with a target of 60 fps and 40 Mb/s. A 30-second session completed after
restarting the iMac. The iMac showed the moving test pattern, and the sender
removed the virtual display at disconnect.

| Measurement | Result |
| --- | --- |
| Network round trip during playback | 0.48 ms mean, 0.66 ms P95, 60 of 60 ping replies |
| Sender encoding, 52 sampled frames | 14.6 ms median, 17.9 ms P95 |

The network probes covered roughly 12 seconds of playback. Encoding time
runs from frame submission to H.264 output. Visible display latency and
the presented frame rate were not measured. Wi-Fi was unavailable for a
matching run. Before the restart, one session dropped and two retries
closed before capture started. The cause on the iMac remains unverified.

A separate 60-second network check while a sender was already connected
returned 240 of 240 ping replies at 0.59 ms mean and 0.94 ms maximum.
That check used the active desktop session as-is.

The updated sender also passed the default four-second loopback capture
and teardown check. The test harness rejects invalid durations and times
out when the selected interface is unavailable. To run a longer teardown
check, set `LUNA_TEST_STREAM_SECONDS` (1–120) with
`--test-disconnect host:port`. Set `LUNA_TRACE_LATENCY=1` for sampled frame
timings and periodic TCP round-trip reports.

## Earlier loopback tests

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

The Intel receiver binary's minimum OS version was checked as macOS 10.15.

## Checks completed

- Both apps built with `arm64` and `x86_64` slices and passed strict ad hoc
  signature checks. The builds were not notarized.
- All three display presets registered with the expected dimensions and
  were removed after the self-test.
- Parser fuzzing and tests for invalid streams, timeouts and reconnects
  passed.
- The packaged sender captured a real virtual display, streamed frames to
  the receiver, and removed the display on disconnect.

These checks cover the November 12 code snapshot.

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
