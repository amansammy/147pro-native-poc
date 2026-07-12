# Overnight work — status & next steps (2026-07-12)

Everything below is deployed to **staging** (`staging.147pro.com`, what the shell
loads). Items marked **RELAUNCH** take effect by force-quitting + reopening the
app. Items marked **REBUILD** need a fresh Codemagic build (latest `main` =
`99e2613`).

## Fixed — RELAUNCH only (no rebuild)
- **Scoreboard now shows on the native preview** (not just the live stream) — the
  overlay push loop runs during preview too.
- **Orientation warning** — native camera hides behind the "rotate to landscape"
  screen instead of covering it.
- **Small scroll on every page** — was Capacitor's `contentInset` double-insetting
  vs `min-height:100vh`. Fixed with `contentInset: never` (REBUILD, see below) +
  `min-height:100dvh`.
- **Occlusion of dialogs/dropdowns/wizard** — the native camera hides whenever any
  Radix dialog/dropdown/menu opens, and restores on close.
- **Top bar**: camera selector made smaller; added a **Lock AF/AE** button
  (focus/exposure lock — also improves sharpness on a fixed table shot).

## Fixed — REBUILD required (native Swift, in `99e2613`)
- **Rounded corners** on the preview + aspect-fill.
- **Pinch-to-zoom** on the preview (`handlePinch`).
- **Edge-swipe back** gesture.
- **`contentInset: never`** (the scroll fix's native half).
- **Native Google sign-in + YouTube connect** — see Auth below.

## Auth (Google + YouTube) — implemented, REBUILD required
**Reuses your EXISTING, already-verified OAuth client — no Google re-verification.**
Google still redirects to the same verified `https` callback; the custom scheme is
only between our server and the app, which Google never sees.

How it works (fixes the `disallowed_useragent` 403):
1. The Sign-in/Connect buttons, when native, open the OAuth flow in **Safari** via
   `ASWebAuthenticationSession` (real Safari UA → Google allows it).
2. Google → our verified `https` callback.
3. The callback detects the native flow and 302s to `pro147auth://…` with a
   single-use token (login) or `success=1` (YouTube).
4. The app exchanges the token at `/_api/auth/establish_session` (login) which sets
   the real session cookie in the WebView. YouTube tokens are already stored
   server-side, keyed to the user via a one-time `ticket`.

Files: server `endpoints/auth/oauth_authorize_GET.ts`, `helpers/oauthCallbackHandler.tsx`,
`endpoints/youtube/{oauth_authorize,oauth_callback}_GET.ts`, `endpoints/youtube/native_ticket_POST.ts`
(+ `server.ts` route); native `StreamerPlugin.startOAuth` (ASWebAuthenticationSession);
web `helpers/nativeAuth.tsx`, `helpers/streamingNativeBridge.tsx`,
`components/OAuthLoginButton.tsx`, `helpers/useYouTubeIntegration.tsx`.

**No Google Console change needed.** After rebuild, test: Sign in with Google →
should open Safari, sign in, return to the app logged in. Then connect YouTube from
the wizard.

## Apple IAP — implemented, NEEDS ENABLEMENT (deliberately not wired into the build)
The upgrade page currently shows Stripe because the old IAP path was Appilix-only.
I added a **StoreKit 2** path that feeds the SAME backend verifier (`/_api/iap/apple/verify`
already validates the signed transaction JWS — no server change).

- `ios/App/App/IapPlugin.swift` — StoreKit 2 `purchase`/`restore`/`getProducts`
  (returns `jwsRepresentation`). Committed but **NOT yet added to the Xcode target**
  (I won't edit `project.pbxproj` blind — a mistake there breaks the whole build).
- Web: `helpers/appleIapClient.ts` (`purchaseNative` / `isNativeIapAvailable` gated on
  the REGISTERED `Plugins.Iap`) + `pages/upgrade.tsx` now prefer native IAP. **Gated
  so it safely falls back to Stripe until the plugin is registered** — zero regression.

To enable (do in Xcode, ~5 min):
1. Add `IapPlugin.swift` to the **App** target (drag into the project / "Add Files",
   ensure Target Membership = App). Confirm `IPHONEOS_DEPLOYMENT_TARGET >= 15.0`.
2. In `MainViewController.capacitorDidLoad()` add:
   `if #available(iOS 15.0, *) { bridge?.registerPluginInstance(IapPlugin()) }`
3. App Store Connect: the products `com.147pro.app.pro_monthly` / `_yearly` already
   exist (from Appilix). Add a **Sandbox tester** and test on device.

Once registered, `Plugins.Iap` appears → the upgrade page automatically uses IAP.

## Known / still open
- **Preview disappears while a menu is open** — inherent to native-on-top; the guard
  hides then restores it. A fuller fix (native-behind + transparent hole) is a bigger
  refactor, not done.
- **Right-side landscape clip** — pre-existing (before any changes). Deliberately NOT
  touched again (blind landscape CSS broke scrolling once). Fix with device eyes.
- **Sponsors / watermark / start-break screens** over the native stream — only the
  scoreboard is bridged so far.
- **Native stream quality** — verified true 1080p60 @ 12 Mbps (diagnostics). Softness
  seen was the broken 1× lens / YouTube ramp; use ultrawide/tele + lock AF/AE.
  See `NATIVE_EFFICIENCY_PLAN.md`.
