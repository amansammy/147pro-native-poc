# 147 Pro — Capacitor Native Migration Plan

_Last updated: 2026-07-11. Author: native-streaming workstream._

Goal: replace the Appilix WebView wrapper of `app.147pro.com` with a **Capacitor**
shell that runs the **same web app** but swaps the streaming engine for the proven
native path (true 1080p60 → RTMP-direct to YouTube, overlays composited natively).
**iOS first**, then **Android**. The live web app and the current App Store app stay
**untouched** until we cut over.

> Nothing in the live product changes until we deliberately flip the switch. All web
> changes land behind an `isNativePlatform()` guard and are exercised on a **staging**
> deployment / bundled build, never on production `app.147pro.com`.

---

## 1. Current architecture (verified, not assumed)

**Frontend**: React 19 + Vite 6 SPA. Built to `dist/`. Radix UI, React Query, React Router.

**Server** (`server.ts`): originally a **Floot serverless** app; Floot generated a
`server.ts` (built on the Hono library) that now runs on the droplet as a **persistent
`node --import tsx server.ts` process on `:3333`** (pm2 name `147pro`, cwd `/opt/147pro`) —
no longer serverless. It explicitly registers every file-based endpoint
(`endpoints/**/*_{GET,POST}.ts`, each exporting `handle(request): Response`), serves
static `dist/` + `static/`, and SPA-falls-back to `dist/index.html`. **nginx** fronts it
(TLS, `app.147pro.com`) and proxies `/` → `127.0.0.1:3333` (plus our isolated `/poc/`
scoreboard service on `:8899`). DB: Postgres via Kysely. **Adding an API route = add
`endpoints/<name>_POST.ts` + one `app.post(...)` line in `server.ts` + redeploy (`deploy/`
scripts + pm2 reload).**

**Streaming today (the part we replace)**: browser `getUserMedia` → a WebGL/2D
**compositor** (`streamingWebGLCompositor` / `streamingCanvasRenderer`) that draws, per
frame: `sourceVideo` (camera) + `overlayBitmap` (scoreboard) + `sponsorImage` +
`screenImage` (start/break/end) + `watermarkImage`, with digital zoom + optional motion
blur → `canvas.captureStream()` → **LiveKit** (WebRTC ingest; `livekit-client`,
`/_api/livekit/token`) → **LiveKit egress** (`/_api/livekit/egress`) → **YouTube RTMP**.
(MediaMTX/WHIP utilities also present as an alternate path.) This is capped at
720p60 / 1080p30 by WebKit `getUserMedia` and looks soft — the reason for going native.

**Overlays (already a bitmap pipeline!)**: `streamingOverlayCache.updateOverlay()` calls
`drawOverlayGraphics(ctx, gameState, 1920, 1080, isMobile, overlayType)` onto an
**offscreen 1920×1080 canvas** for every board type (`default`, `variant`,
`proTv2`–`proTv5`, `pool9ball`) → `ImageBitmap`, **cached by a game-state hash** (redraws
only on change; a 250 ms time-bucket keeps the pool shot clock ticking). Sponsor / screen /
watermark are **separate image layers** composited in the WebGL step.

**YouTube (already server-side!)**: per-user OAuth (`/_api/youtube/oauth_authorize` +
`oauth_callback`). `POST /_api/youtube/broadcast_create` returns
`{ broadcastId, streamId, streamKey, rtmpUrl, streamUrl }`. `broadcast_update` transitions
to live; `disconnect` unlinks. **This means native Go Live needs no manual stream keys.**

**Streaming session state**: `/_api/streaming/{start,stop,active-info,clean-stale}`.

**Auth**: web OAuth (`/_api/auth/oauth_*`, incl. Google). Appilix provided native Google
sign-in that we must replace.

**Payments**: Stripe (web checkout + webhook + portal) **and** Apple IAP with server
verification already built (`/_api/iap/apple/{verify,notifications,debug}`). Both in test
mode; Pro tier not yet released. Appilix currently brokers the Apple IAP purchase.

**iOS today**: Appilix WebView wrapper, live in App Store ~6 months.

---

## 2. Target architecture

- **Capacitor shell** loads the **same** React web app. It exposes a native `Streamer`
  plugin (already built + proven in this PoC repo).
- The **web streaming UI is unchanged** (camera selector, zoom, overlay picker, sponsors,
  screens, watermark are all already there). Only the **engine** swaps: when
  `Capacitor.isNativePlatform()` is true, capture/composite/publish route to the native
  plugin; otherwise the existing LiveKit/WebRTC path runs (browser users).
- **Native Streamer plugin** (this repo, `ios/App/App/StreamerPlugin.swift`): AVFoundation
  1080p60 capture, H.264 **High/AutoLevel**, **RTMP-direct to YouTube**, overlay via
  `ImageScreenObject` **bitmap bridge**, lens switch / zoom / focus-exposure lock,
  thermal-adaptive bitrate, auto-reconnect.
- **YouTube**: native reuses the existing `broadcast_create` → `{rtmpUrl, streamKey}` →
  `Streamer.startStream(...)` → `broadcast_update` (go live). No new streaming infra.
- **MediaMTX / LiveKit egress**: retired for the native path (phone pushes RTMP straight to
  YouTube). Kept only as long as we keep a browser fallback. → the eventual MediaMTX-kill.

---

## 3. The web↔native bridge (concrete)

New web module `helpers/streamingNativeBridge.ts` (only active when native; a no-op import
for the browser build):

```ts
import { Capacitor, registerPlugin } from '@capacitor/core';
export const isNativeStreaming = () => Capacitor?.isNativePlatform?.() === true;
const Streamer = isNativeStreaming() ? registerPlugin<StreamerPlugin>('Streamer') : null;
export interface StreamerPlugin {
  startPreview(o: {width:number;height:number;fps:number;lens?:string}): Promise<void>;
  startStream(o: {url:string;streamKey:string;width:number;height:number;fps:number;bitrate:number}): Promise<void>;
  stopStream(): Promise<void>;
  setLens(o: {lens:'wide'|'ultrawide'|'tele'|'front'}): Promise<void>;
  setZoom(o: {factor:number}): Promise<void>;
  setFocusExposureLock(o: {locked:boolean}): Promise<void>;
  updateOverlay(o: {image:string}): Promise<{ok:boolean}>;
  addListener(ev:'status', cb:(d:any)=>void): void;
}
export const nativeStreamer = () => Streamer;
```

**Go Live (native branch)** — reuse the existing flow:
1. `broadcast_create` (existing) → `{ rtmpUrl, streamKey }`.
2. `Streamer.startPreview(...)` then `Streamer.startStream({ url: rtmpUrl, streamKey, 1920,1080,60, bitrate })`.
3. `broadcast_update` → live (existing). `streaming/start` bookkeeping (existing).
**Stop**: `Streamer.stopStream()` + `streaming/stop` + broadcast end (existing).

**Overlay push** — reuse the existing renderer, change only the sink:
- New `helpers/streamingNativeOverlay.ts`: `renderOverlayCompositeToCanvas(state)` draws, in
  z-order, onto ONE transparent 1920×1080 2D canvas: (full-screen `screenImage` if active)
  else [`drawOverlayGraphics(...)` scoreboard + `sponsorImage` + `watermarkImage`]. All of
  this drawing already exists (scoreboard via `drawOverlayGraphics`; the others are
  `ctx.drawImage`).
- A small loop keyed off the **existing `fastGameStateHash` + sponsor/screen/watermark
  state**: only when the composite changes, `canvas.toDataURL('image/png')` →
  `Streamer.updateOverlay({ image })`. Native swaps the `ImageScreenObject` cgImage. Cheap
  (a few pushes/sec at most; shot-clock already time-bucketed).
- **One native code path for ALL overlays** — native just composites whatever pixels the web
  draws, so every board + sponsors + watermark + screens carry over with zero native rework.

**Camera controls** — route the existing UI handlers in native mode:
- `streamingControlsCameraHandlers` lens change → `Streamer.setLens(...)`.
- `streamingZoomUtils` → `Streamer.setZoom({factor})`.
- New focus/exposure-lock toggle → `Streamer.setFocusExposureLock({locked})`.
- (Browser mode keeps `applyConstraints` / `getUserMedia`.)

**Preview** — native camera preview renders **behind** the transparent WebView (PoC does
this). In native mode, hide the web `<video>`/compositor canvas in `StreamingPreview`; the
native preview shows through. Overlays are visible because they're composited natively.

---

## 4. Native plugin — status & remaining Swift work

Done (this PoC): `startPreview/startStream/stopStream`, `setLens`, `setZoom`,
`setFocusExposureLock`, `updateOverlay(image)`→`ImageScreenObject`, thermal-adaptive
(critical-only), auto-reconnect, stop/start teardown, landscape 1080p60 High/AutoLevel,
true-native capture preset.

To add for parity:
- `hideOverlay()` (or `updateOverlay({image:''})`) to clear the board (screens/none).
- `stopPreview()` / proper teardown on app background; mic-mute toggle if the UI has one.
- Confirm behaviour when a **full-screen "screen"** image is pushed (opaque full-frame over
  camera) — already works (image covers the frame).
- Optional: surface capture caps / errors to JS `status` for the UI.

---

## 5. Capacitor project & environments

- **Evolve this PoC repo** into the real shell. For development keep
  `appId = com.pro147.poc` so it **installs alongside** the live app and the App Store app is
  untouched. Flip to the **live bundle id** only at store-submission time (in-place update
  over Appilix; signing already solved with our own key).
- **Where does the shell load the web app from?** Options:
  - **A. Staging via `server.url`** _(recommended for fast iteration)_: run a **second**
    instance of the web app (the native-enhanced branch) on the droplet (e.g. `:3334`, nginx
    at `staging.147pro.com` or `/staging`), point `capacitor.config server.url` there. Web
    changes = redeploy staging (instant, **no app rebuild**). Production untouched.
  - **B. Bundled `www`**: build the native-enhanced web app into the Capacitor bundle. Fully
    offline, but every web change needs a native rebuild + TestFlight (slow).
  - **C. `server.url = app.147pro.com`**: only after cut-over, when production carries the
    native branches.
  - → Use **A (staging)** now; move to bundled/production for store submission.

---

## 6. Replacing the Appilix integrations

- **Google Sign-In**: reuse the existing web OAuth (`/_api/auth/oauth_authorize` → Google →
  `oauth_callback`) but make the redirect return to the app. Options: (a) `@capacitor/browser`
  in-app browser + a custom-scheme / Universal Link redirect back into the app; (b) a native
  Google Sign-In plugin that yields an `id_token` posted to a small `native-login` endpoint.
  → Start with (a) (reuses existing endpoints); fall back to (b) if WebView OAuth is painful.
- **Apple IAP**: add a Capacitor IAP plugin (RevenueCat or `@capacitor-community/in-app-purchases`).
  On purchase, send the transaction/receipt to the **existing** `/_api/iap/apple/verify` →
  entitlement. Replaces Appilix's purchase trigger. (Server side already built + in test.)
- **Stripe**: **no change** — runs in the web layer. Keep the existing split: **iOS → Apple
  IAP** (Apple requires it for digital goods), **web → Stripe**. Gate the Pro upgrade UI by
  `Capacitor.getPlatform()`.

---

## 7. Execution order (tonight target: iOS streaming working)

1. **Shell → staging**: stand up the staging web instance; set `server.url` to it; keep
   `com.pro147.poc`. Rebuild once. App now loads the real 147 Pro app with `Streamer` present.
2. **Bridge module** (`streamingNativeBridge.ts`) + feature detection. No behaviour change
   for browser.
3. **Native Go Live**: in the streaming start handler, `if (isNativeStreaming())` → use
   `broadcast_create`'s `rtmpUrl/streamKey` with `Streamer.startStream`; skip LiveKit. Wire
   Stop.
4. **Preview**: hide web video/canvas in native; native preview shows through.
5. **Overlays**: `renderOverlayCompositeToCanvas` + change-keyed `updateOverlay` push.
6. **Controls**: lens / zoom / focus-lock → `Streamer.*` in native mode.
7. **End-to-end test** on friend's phone via the app's own YouTube broadcast flow.
8. **Auth + IAP** migration (can follow after streaming is solid).
9. **Store submission**: flip bundle id, signing, review, in-place update over Appilix.
10. **Android**: Capacitor Android + a `Streamer` plugin backed by **RootEncoder**
    (pedroSG94), same JS bridge/API.
11. **Retire MediaMTX / LiveKit egress** once native is the only streaming path. 🔪

---

## 8. Guardrails / open decisions

- **Production safety**: every web-side change is behind `isNativePlatform()`; developed on
  staging/branch; production `app.147pro.com` and the Appilix App Store build are untouched
  until cut-over.
- `server.url` staging vs bundled (offline + App Store review) — decide before submission.
- Keep the browser WebRTC path as a fallback, or go native-only on mobile? (Affects whether
  MediaMTX/LiveKit can die immediately.)
- OAuth-in-WebView redirect handling (Google).
- iOS IAP vs Stripe gating by platform.
- Overlay push rate / battery: reuse the existing cache-invalidation key; cap fps.
- Resolution assumption: overlay PNG rendered at 1920×1080 (stream 1080p); handle 720p if
  ever used.

---

## 9. Key files (main app) this touches

- Engine swap: `helpers/useStreamingControlsHandlers.tsx`, `helpers/useStreamingControlsState.tsx`,
  `helpers/streamingLiveKitUtils.tsx` / `streamingMediaMtxUtils.tsx` (branch, don't delete),
  `helpers/useStreamingCredentials.tsx`.
- Overlays: `helpers/streamingOverlayRenderer.tsx` (reused as-is), `helpers/streamingOverlayCache.tsx`
  (mirror its change-detection for the native sink), new `helpers/streamingNativeOverlay.ts`.
- Camera: `helpers/streamingControlsCameraHandlers.tsx`, `helpers/streamingZoomUtils.tsx`,
  `helpers/streamingCameraUtils.tsx`.
- Preview UI: `components/StreamingPreview.tsx`, `components/StreamingActiveControls.tsx`.
- Go Live: `endpoints/youtube/broadcast_create` (reuse), `endpoints/streaming/start|stop` (reuse).
- New: `helpers/streamingNativeBridge.ts`.

## 10. Native repo (this repo) files

- `ios/App/App/StreamerPlugin.swift` (engine), `MainViewController.swift` (plugin registration),
  `capacitor.config.json` (appId / server.url), `Podfile` (HaishinKit 2.0.9),
  `codemagic.yaml` (cloud build → TestFlight). Android to be added under `android/`.
