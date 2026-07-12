# Native Streaming — Efficiency & Quality Plan

Context: the native (Capacitor + HaishinKit) path streams true 1080p60 RTMP-direct
to YouTube. Device diagnostics from the last test (`/opt/147pro/stream-diag.log`,
`native-stream-diag` frames) confirm the encode is correct:

```
videoSettings.applied  w=1920 h=1080  profile=H264_High_AutoLevel  bitRate=12000000
media.tick             fps≈60  bytesPerSec≈1.57M (≈12.5 Mbps)  readyState=publishing
```

So the pipeline is NOT the bottleneck for resolution — the encoder and uplink are
doing genuine 1080p60 @ 12 Mbps. This doc separates what actually helps us from
generic advice.

---

## Our real pipeline (for reference)

```
AVCaptureDevice (lens, sessionPreset 1920x1080)
  → MediaMixer (.offscreen compositor, screen size 1920x1080)
      + ImageScreenObject overlay  ← web renders a 1920x1080 PNG, pushed via updateOverlay (bitmap bridge)
  → VideoToolbox H.264 High/AutoLevel (hardware)
  → RTMPStream → RTMP → YouTube
Preview: MTHKView shows the mixer output, behind a transparent WebView.
JS only controls: start/stop, lens, zoom, focus/exposure, overlay bitmap.
```

**Video frames never pass through JavaScript.** Only the overlay bitmap crosses the
bridge.

---

## GPT's list, triaged against our code

| # | Suggestion | Verdict for us |
|---|------------|----------------|
| 1 | Don't render overlay in WebView | **Partially relevant.** We don't composite HTML over the preview — but we DO render the scoreboard to a PNG in a JS canvas and push it over the bridge every 500ms. That's JS/CPU work. See Action A. |
| 2 | Don't preview at full res | Minor. MTHKView previews the composited output; see Action D. |
| 3 | Use hardware encoding (VideoToolbox) | **Already done.** VideoToolbox H.264. No FFmpeg/x264 anywhere. |
| 4 | Reduce bitrate (6–8 Mbps) | Optional. 12 Mbps is a *ceiling*; thermal-adaptive already backs off only at `critical`. We keep 12 as the top slider stop for quality; default could be 9. See Action E. |
| 5 | Avoid unnecessary copies (Camera→UIImage→Canvas→JS→native) | **Already avoided.** Camera→mixer→encoder→socket is all native; JS never touches video frames. |
| 6 | Keep everything native after capture | **Already done.** |
| 7 | Lower preview frame rate (not stream) | Relevant, small. See Action D. |
| 8 | Disable HDR / stabilization / EDR / auto-macro | **Relevant — and may improve perceived sharpness too.** See Action B. |
| 9 | Lock focus/exposure | **Relevant.** We have `setFocusExposureLock` but no UI button yet. See Action C. |
| 10–12 | Wi‑Fi quality, screen brightness, Low Power Mode | Operational, not code. Worth telling the user; nothing to build. |
| — | AVCaptureMovieFileOutput / WHIP-WebRTC | N/A — we don't use either. |

---

## Actions, prioritized (impact first)

### A. Make the overlay bridge event-driven, not a 500ms poll  ·  impact: CPU + latency
Today `startStreamInternal` runs a 500ms `setInterval` that re-renders the board
and (change-guarded) pushes it. That's steady JS/canvas work and adds up to ~0.5s
of scoreboard latency — which matches the "slight delay" seen when scoring from the
remote link. Replace the interval with a push driven directly off the game-state
change (the SSE update / `gameStateRef` change) so we render+push exactly once per
actual score change, immediately. Keep a low-rate fallback tick only for the pool
shot-clock (which must animate).
Files: `helpers/streamingHelpers.tsx` (native branch), `helpers/streamingNativeOverlay.tsx`.

### B. Disable video HDR + stabilization on the capture device  ·  impact: heat + look
On `AVCaptureDevice`/format, force `automaticallyAdjustsVideoHDREnabled = false`,
`videoHDREnabled = false`, and set `preferredVideoStabilizationMode = .off` (or
`.standard` at most). HDR/EDR video adds ISP load and can make the image look
over-processed/soft and inconsistent under club lighting; turning it off is both
cooler and often *cleaner*. Pick the capture format deliberately (highest-res
420f format at the target fps) instead of relying on the preset alone.
File: `ios/App/App/StreamerPlugin.swift` (`setupPipeline` / `cameraDevice`).

### C. Wire the focus/exposure lock to a button  ·  impact: sharpness + ISP
`setFocusExposureLock` already exists natively. Add a control in the streaming UI
(and default to locking once framed) so the camera stops hunting on a fixed table
shot — sharper image, less continuous ISP work.
Files: `components/StreamingControls.tsx` (button) → `helpers/streamingNativeBridge.tsx` (`nativeSetFocusExposureLock`, already exported).

### D. Cap preview frame rate at 30  ·  impact: GPU (small)
The encoded stream stays 60fps; the on-screen MTHKView preview can render at 30.
Requires a small native change to decouple preview render rate from the mixer, so
this is lower priority than A–C.
File: `ios/App/App/StreamerPlugin.swift`.

### E. Sensible default bitrate  ·  impact: heat (optional)
Keep the 12 Mbps top stop, but the *default* slider position for 1080p60 can be
9 Mbps (YouTube's recommendation) — visually indistinguishable for most scenes,
less heat/bandwidth. Already fps-aware in `getNativeBitratePresets`.
File: `components/StreamingSetupWizard.tsx` (default `qualityPreset`).

---

## The "looks like upscaled 720p" finding (not on GPT's list)

The encode is verified true 1080p60 @ 12 Mbps, so softness is capture/playback side:

1. **Broken 1× (Wide) lens on the test phone** — a soft source looks low-res at any
   encode resolution. Use Ultra-Wide (0.5x) or Telephoto (3x). (At the club it was
   crisp because that phone's lenses were fine.)
2. **YouTube quality ramp** — a fresh stream serves a soft low-latency rendition for
   1–2 minutes and the player's "Auto" often stays there. Manually select 1080p60.
3. **Autofocus hunting** — Action C (lock focus) directly addresses this.
4. HDR/EDR over-processing — Action B.

Priority order to "make it look good first": **B + C** (cleaner, sharper capture),
verify with a known-good lens and manual 1080p60 selection in the YouTube player.
Then **A** for latency, then D/E for heat.
