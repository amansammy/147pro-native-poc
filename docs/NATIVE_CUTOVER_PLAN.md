# 147 Pro — Native App Cutover Plan & System Handoff

_Last updated: 2026-07-15._
_Purpose: replace the current Appilix-wrapped iOS app with our own Capacitor app
that does **true native 1080p60 streaming** (HaishinKit → YouTube RTMP), plus a
full map of what exists, what's done, and what's left._

---

## 1. The three environments (system map)

| | **Production (main app)** | **Staging** | **Native PoC (the new app)** |
|---|---|---|---|
| Domain | `app.147pro.com` | `staging.147pro.com` | (wraps staging today) |
| Server dir | `/opt/147pro` | `/opt/147pro-staging` | — |
| Port (behind nginx) | `3333` | `3334` | — |
| Droplet | `67.205.145.174` (DigitalOcean) | same droplet | — |
| Database | Postgres `p147` | **shares the SAME `p147`** | — |
| Local source | `D:\147Pro-main` (**NOT git** — deploy via `scp`) | (same source, deployed) | `D:\147pro-native-poc` (**git → Codemagic → TestFlight**) |
| iOS today | Appilix wrapper of `app.147pro.com` | — | Capacitor 7 shell, `server.url = https://staging.147pro.com` |
| Streaming today | MediaMTX / WHIP (web WebRTC, ~720p ceiling) | **native HaishinKit 1080p60 (WORKS)** | the native `StreamerPlugin.swift` lives here |

**Tech stack (main app):** React 19 + Vite SPA served by a Floot-generated Hono
server (`server.ts`), run under `pm2`. Endpoints are `.ts` files run via `tsx`
(no build step for endpoints); web/CSS/`.tsx` components need `vite build`.

**The plan in one line:** the Capacitor PoC (`D:\147pro-native-poc`) becomes the
real App Store app, pointed at prod, doing native streaming — retiring both
Appilix and MediaMTX.

---

## 2. Deploy / build workflows (IMPORTANT)

**Main app (staging or prod)** — no git; edit locally then:
```bash
# from D:\147Pro-main
scp helpers/foo.tsx components/Bar.tsx root@67.205.145.174:/tmp/
ssh root@67.205.145.174 "cp /tmp/foo.tsx /opt/147pro-staging/helpers/ && \
  cp /tmp/Bar.tsx /opt/147pro-staging/components/ && \
  cd /opt/147pro-staging && npx vite build && \
  pm2 reload 147pro-staging --update-env && sleep 3 && curl -s -o /dev/null -w '%{http_code}' http://localhost:3334/"
```
- **Endpoints (`endpoints/**.ts`)** run via `tsx` → **no `vite build` needed**, just `pm2 reload`.
- **Components/helpers/CSS (`.tsx`/`.css`)** → **`vite build` required**, then reload.
- **Prod = same but `/opt/147pro`, `pm2 reload 147pro`, port `3333`.** Keep prod untouched until cutover except for genuine prod incidents.
- If you scp `server.ts`, RE-SED the port back (staging listens on 3334; a copied prod `server.ts` uses 3333 → EADDRINUSE).

**Native PoC** — is git:
```bash
# from D:\147pro-native-poc
git add ios/App/App/StreamerPlugin.swift && git commit -m "..." && git push origin main
# → Codemagic builds → TestFlight. User relaunches / rebuilds on device.
```
- **JS changes deploy to staging (no rebuild)** — the shell loads the web app from `server.url`. Just relaunch the app to pick up new JS.
- **Native (`.swift`) changes need a Codemagic rebuild.**

**Native streaming diagnostics:** the plugin POSTs `native-stream-diag` frames to
a hardcoded `https://app.147pro.com/_api/stream-diag`:
```bash
ssh root@67.205.145.174 "grep native-stream-diag /opt/147pro/stream-diag.log | tail -80"
```

**DB backup:** `/opt/backups/p147_*.dump` on the droplet + `C:\Users\yourl\147pro-backups\`.
Restore: `sudo -u postgres pg_restore --clean --if-exists -d p147 <dump>`.

---

## 3. What's DONE (native app capabilities — all confirmed on device)

### Streaming (the hard part — WORKS)
- **True 1080p60 → YouTube via HaishinKit RTMP** (no MediaMTX, no WebRTC ceiling).
- The key fix after a long saga: the real app's React effects call `startPreview`
  ~4×/sec; a **`captureConfigured` guard** in `StreamerPlugin.setupPipeline` runs
  the camera setup once so that churn is harmless. Pipeline otherwise mirrors the
  proven "club" PoC: single `setVideoMixerSettings(.offscreen)`, direct `goLive()`.
- **Preview fed from the MIXER** (`mixer.addOutput(view)`), so the composited
  camera+overlays show continuously — before, during, and after streaming.
- **Overlays on preview + stream:** scoreboard (Pro-TV boards / pool 9-ball),
  **watermark, sponsor logos, full-screen "screens"** — all composited into a
  1920×1080 transparent PNG in `helpers/streamingNativeOverlay.tsx` and pushed to
  native. (Earlier only the scoreboard rendered; sponsors/screens/watermark were
  added 2026-07-15.)
- **Scoreboard on preview before go-live:** the game-state SSE/poll feed now runs
  during preview (`nativePreviewActive`), so the board has data pre-live.
- Camera lens switch (wide/ultrawide/tele/front), pinch-to-zoom, focus/exposure
  lock, rounded preview corners, edge-swipe back, thermal-adaptive bitrate,
  auto-reconnect.
- **Mute** (`setMuted` → `AudioMixerSettings.isMuted`), **live stats indicator**
  (fps/res/bitrate from `media.tick` status frames), **"Pinch to zoom" caption**.

### Auth (reuses the EXISTING verified Google/YouTube OAuth clients — no re-verification)
- Google blocks OAuth in WKWebView (`disallowed_useragent`). Fix:
  `StreamerPlugin.startOAuth` opens **ASWebAuthenticationSession** (real Safari) →
  server `oauth_authorize?native=1` → Google hits the SAME verified https callback
  → 302 to custom scheme `pro147auth://` → web exchanges via `establish_session`.
- Files: `helpers/nativeAuth.tsx`, `endpoints/auth/oauth_authorize_GET.ts`,
  `helpers/oauthCallbackHandler.tsx`, `endpoints/youtube/{oauth_authorize,oauth_callback}_GET.ts`,
  `endpoints/youtube/native_ticket_POST.ts`, `OAuthLoginButton.tsx`, `useYouTubeIntegration.tsx`.
- **Google login CONFIRMED working. YouTube connect works on staging.**

### Apple IAP (implemented, NOT yet enabled)
- `ios/App/App/IapPlugin.swift` = StoreKit 2, returns the same `jwsRepresentation`
  the existing `/_api/iap/apple/verify` already validates (no server change).
- Web: `helpers/appleIapClient.ts` (`purchaseNative`/`isNativeIapAvailable`, falls
  back to Stripe until wired) + `pages/upgrade.tsx`.
- **TO ENABLE:** add `IapPlugin.swift` to the App target in Xcode (deployment
  target ≥ 15) and register it in `MainViewController` (`if #available(iOS 15,*){ bridge?.registerPluginInstance(IapPlugin()) }`).
  ASC products `com.147pro.app.pro_monthly/_yearly` exist. NOT in pbxproj yet.

---

## 4. CUTOVER STEPS (staging → replace Appilix on prod)

1. **Confirm staging is fully green** on device (streaming, overlays, auth, mute,
   stats, screens). — essentially done.
2. **Deploy the native-streaming web changes to PROD** (`/opt/147pro`). These are
   the `helpers/streaming*.tsx`, `helpers/streamingNative*.tsx`, `helpers/nativeAuth.tsx`,
   `components/Streaming*.tsx`, `components/CameraPreview.tsx`, `components/ScreenPicker.tsx`,
   and the native-branch OAuth endpoints. Same `scp + vite build + pm2 reload 147pro`.
   > These are guarded by `isNativeStreamingAvailable()` and only change behaviour
   > inside the native shell, so deploying to prod is safe for existing web/Appilix users.
3. **Give staging its OWN Google OAuth client.** Right now staging and prod SHARE
   one YouTube OAuth client (and the DB) — editing that client for staging is what
   broke prod OAuth on 2026-07-15 (see §5). Create a separate client for staging and
   put its id/secret in `/opt/147pro-staging/env.json` so testing can never hit prod.
4. **Point the Capacitor shell at prod:** in `D:\147pro-native-poc\capacitor.config.json`
   set `server.url = https://app.147pro.com`, commit, push → Codemagic build.
5. **Enable Apple IAP** (§3) so the upgrade flow uses StoreKit instead of Stripe on iOS.
6. **Ship to the App Store** as an update to the existing 147 Pro app (bundle
   `com.snooker147pro.app`), replacing the Appilix build. Requires a **valid iOS
   Distribution certificate + provisioning profile** (currently broken — see §5).
7. **Kill MediaMTX** once native is the only streaming path.

**Config facts:** `capacitor.config.json` → `server.url`, `appendUserAgent:"147ProNative"`,
`ios.contentInset:"never"`. App bundle id = `com.snooker147pro.app`.

---

## 5. OPEN ISSUES / BLOCKERS

- **🔴 PROD YouTube OAuth is broken (2026-07-15).** Google returns
  `unauthorized_client` on the token exchange for ALL users. Proven NOT the server:
  the outbound request is textbook-correct (right client `130503224254-kmh7utc…`,
  enabled secret `…4M6o`, matching `redirect_uri`, valid `4/` code) yet Google
  rejects it. Prod YouTube connect uses **Appilix native Google sign-in**, which
  depends on the **iOS OAuth client** (`130503224254-cq44o2…`, bundle
  `com.snooker147pro.app` — matches) and a validly **signed app**. The App Store
  provisioning profile **"147 Pro" shows Invalid** in Apple Developer → almost
  certainly an **expired/revoked iOS Distribution certificate** (likely lapsed
  ~2026-07-15, matching the exact break time). **Fix (Apple side): regenerate the
  iOS Distribution cert → regenerate the "147 Pro" profile → rebuild/re-sign.** Not
  fixable from the server. Prod helper backup: `/opt/147pro/helpers/youtubeOAuthHelper.tsx.bak-20260715_195010`.
  > This same broken cert/profile will block the App Store submission in §4.6, so
  > fixing it unblocks BOTH prod OAuth and the cutover.
- **🟡 Apple IAP** not yet enabled in Xcode (§3).
- **🟡 Native mute** shipped in commit `25c3e36` (native) — needs the next
  Codemagic rebuild to take effect on device.
- **🟡 Shared OAuth client + shared DB** between staging and prod (§4.3) — separate them.
- **ℹ️ Screens redesign** now uses a single "Screen" (the old start-screen slot) +
  an image library in `localStorage` (`floot_screen_library_v1`). The old
  break/end screen slots are unused; `StreamScreensManager.tsx` is now dead code.

---

## 6. Key native files (in `D:\147pro-native-poc`)

- `ios/App/App/StreamerPlugin.swift` — the HaishinKit streaming plugin (capture,
  offscreen compositor, RTMP, overlay bitmap bridge, lens/zoom/focus, `setPreviewRect`,
  `setMuted`, `startOAuth`, auto-reconnect, thermal). Written against **HaishinKit 2.0.9**.
- `ios/App/App/IapPlugin.swift` — StoreKit 2 (not in pbxproj yet).
- `ios/App/App/MainViewController.swift` — registers plugins via `bridge?.registerPluginInstance(...)`.
- `capacitor.config.json` — `server.url` (staging today → prod on cutover).
- `docs/` — `CAPACITOR_MIGRATION_PLAN.md`, `NATIVE_EFFICIENCY_PLAN.md`, `OVERNIGHT_STATUS.md`.

## 7. Key web files (in `D:\147Pro-main`, deployed to staging/prod)

- `helpers/streamingNativeBridge.tsx` — typed wrapper on `window.Capacitor.Plugins.Streamer`
  (plugin acquired via `Plugins.Streamer` → `registerPlugin('Streamer')` fallback;
  `isNativeStreamingAvailable()` gates the native path). Exposes `nativeStartStream`,
  `nativeSetMuted`, `nativeSetPreviewRect`, `onNativeStatus`, etc.
- `helpers/streamingNativeOverlay.tsx` — renders scoreboard + sponsor + watermark +
  screen into a 1920×1080 PNG → `nativeUpdateOverlay`.
- `helpers/streamingHelpers.tsx` — the big streaming hook; native branches in
  start/stop, `nativePreviewActive` game-state feed, `nativeStreamStats`, overlay loop.
- `components/StreamingControls.tsx` — top bar (camera selector, focus lock, **stats
  indicator**, go-live/mute), side menu (Score Overlay, Sponsors, **Screen**, Watermark).
- `components/ScreenPicker.tsx` (+ `.module.css`) — the new Screen image library modal.
- `components/CameraPreview.tsx` / `StreamingPreview.tsx` — native preview rect
  reporting (+ reserved strip for the "Pinch to zoom" caption).
- `helpers/nativeAuth.tsx`, `helpers/appleIapClient.ts` — native auth + IAP.

---

## 8. Quick reference

- Droplet: `ssh root@67.205.145.174`. Prod pm2 id `0` (`147pro`, :3333), staging id `2` (`147pro-staging`, :3334).
- nginx: `/etc/nginx/sites-enabled/{app,staging}.147pro.com`. certbot certs.
- Env: `/opt/147pro/env.json` (loaded by `loadEnv.js` — NOT `.env`). Keys: `YOUTUBE_CLIENT_ID/SECRET`,
  `GOOGLE_OAUTH_CLIENT_ID/SECRET`, `APPLE_*`, `STRIPE_*`, `FLOOT_DATABASE_URL`, `JWT_SECRET`, `RESEND_API_KEY`.
- Google project `130503224254`: web "Youtube OAuth Client" `…kmh7utc…goe`, iOS "iOS App Login"
  `…cq44o2…` (bundle `com.snooker147pro.app`).
- Codemagic builds the native PoC from `github.com/amansammy/147pro-native-poc`.
