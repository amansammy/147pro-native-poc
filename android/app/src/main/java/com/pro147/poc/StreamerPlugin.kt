package com.pro147.poc

import android.Manifest
import android.content.Intent
import android.graphics.Color
import android.net.Uri
import android.os.Handler
import android.os.Looper
import android.view.SurfaceHolder
import android.view.SurfaceView
import android.view.ViewGroup
import android.widget.FrameLayout
import com.getcapacitor.JSObject
import com.getcapacitor.PermissionState
import com.getcapacitor.Plugin
import com.getcapacitor.PluginCall
import com.getcapacitor.PluginMethod
import com.getcapacitor.annotation.CapacitorPlugin
import com.getcapacitor.annotation.Permission
import com.getcapacitor.annotation.PermissionCallback
import androidx.browser.customtabs.CustomTabsIntent
import com.pedro.common.ConnectChecker
import com.pedro.encoder.utils.CodecUtil
import com.pedro.library.generic.GenericStream
import com.pedro.library.util.BitrateAdapter
import com.pedro.library.util.FpsListener
import org.json.JSONObject
import java.net.HttpURLConnection
import java.net.URL
import java.util.Timer
import java.util.TimerTask
import java.util.UUID

/**
 * Android native streaming plugin — the RootEncoder counterpart to the iOS
 * HaishinKit StreamerPlugin. Same JS bridge contract (jsName "Streamer", same
 * methods/events) so the web app drives both platforms with zero web changes.
 *
 * v1 = verified core (RootEncoder 2.6.1): permissions, preview, 1080p60 H.264 →
 * RTMP(S), stop, connection lifecycle, media.tick. Overlays/zoom/mute/lens are
 * stubbed no-ops until basic streaming is confirmed. Emits diagnostics to the
 * server (stream-diag.log, tagged platform=android) for remote debugging.
 */
@CapacitorPlugin(
    name = "Streamer",
    permissions = [
        Permission(alias = "camera", strings = [Manifest.permission.CAMERA]),
        Permission(alias = "microphone", strings = [Manifest.permission.RECORD_AUDIO])
    ]
)
class StreamerPlugin : Plugin(), ConnectChecker {

    private var genericStream: GenericStream? = null
    private var previewView: SurfaceView? = null
    private var previewContainer: FrameLayout? = null
    private var previewStarted = false
    private var wantPreview = false
    private var prepared = false
    private var preparedW = 0
    private var preparedH = 0
    private var preparedFps = 0

    private var streamW = 1920
    private var streamH = 1080
    private var streamFps = 60
    private var targetBitrate = 9_000_000

    // Last real (non-zero) preview size, so a "hide" (rect 0×0 from the web's
    // occlusion guard) can move the surface OFF-SCREEN at its real size instead of
    // resizing it to 0 — resizing to 0 destroys the SurfaceView's surface and tears
    // down RootEncoder's preview (churn → black/gray). iOS just repositions; Android
    // must keep the surface alive.
    private var lastPreviewW = 0
    private var lastPreviewH = 0

    private var lastBitrate: Long = 0
    private var actualFps = 0
    private var isLive = false
    private var diagTimer: Timer? = null

    // Smoothly adapts the encoder bitrate to network congestion (RootEncoder's own
    // mechanism) instead of the pipeline hard-stalling when the uplink can't sustain
    // the target — which was causing the bitrate to swing 5–15 Mbps, YouTube to
    // buffer, and the coupled preview to stutter.
    private val bitrateAdapter = BitrateAdapter { bps -> genericStream?.setVideoBitrateOnFly(bps) }

    // OAuth (Google login / YouTube connect) runs in a Chrome Custom Tab — Google
    // blocks OAuth in a WebView. The pending call is resolved from handleOnNewIntent
    // when the server redirects to pro147auth://.
    private var oauthCall: PluginCall? = null
    private var oauthScheme: String? = null

    // Remote diagnostics: POST to the server so we can debug the device without
    // an on-screen error. Tagged so Android entries are distinguishable in the log.
    private val diagEnabled = true
    private val diagTag = UUID.randomUUID().toString().substring(0, 8)

    // ------------------------------------------------------------------
    // Lifecycle helpers
    // ------------------------------------------------------------------

    private fun ensureStream(): GenericStream {
        genericStream?.let { return it }
        val s = GenericStream(context, this).apply {
            getGlInterface().autoHandleOrientation = true
        }
        // Force the hardware H.264 VIDEO encoder — a software fallback would choke on
        // 1080p60 and cause the stutter (and heat). Audio (AAC) has no hardware codec,
        // so leave it FIRST_COMPATIBLE_FOUND — forcing HARDWARE audio makes
        // prepareAudio fail. Must be set before prepareVideo/prepareAudio.
        try {
            s.forceCodecType(CodecUtil.CodecType.HARDWARE, CodecUtil.CodecType.FIRST_COMPATIBLE_FOUND)
        } catch (_: Exception) {}
        // Real encoded fps for the diag + on-screen readout.
        try { s.setFpsListener(FpsListener.Callback { fps -> actualFps = fps }) } catch (_: Exception) {}
        genericStream = s
        reportDiag("stream.created")
        return s
    }

    private fun hasCapturePermissions(): Boolean {
        return getPermissionState("camera") == PermissionState.GRANTED &&
            getPermissionState("microphone") == PermissionState.GRANTED
    }

    // ------------------------------------------------------------------
    // Preview
    // ------------------------------------------------------------------

    @PluginMethod
    fun startPreview(call: PluginCall) {
        // Prepare the encoder at 1080p60 regardless of the persisted preview quality
        // the web passes (often 720p/30). This gives a smooth 60fps preview AND means
        // the common 1080p60 go-live reuses the same prepared encoder (no disruptive
        // stop/re-prepare churn). A non-1080p60 broadcast still re-prepares on go-live.
        streamW = 1920
        streamH = 1080
        streamFps = 60
        reportDiag("startPreview.call", mapOf(
            "w" to streamW, "h" to streamH, "fps" to streamFps,
            "reqW" to call.getInt("width", 0), "reqFps" to call.getInt("fps", 0)
        ))

        if (!hasCapturePermissions()) {
            reportDiag("perms.request")
            requestAllPermissions(call, "onCapturePermsResult")
            return
        }
        startPreviewInternal(call)
    }

    @PermissionCallback
    private fun onCapturePermsResult(call: PluginCall) {
        val granted = hasCapturePermissions()
        reportDiag("perms.result", mapOf("granted" to granted))
        if (!granted) {
            call.reject("Camera and microphone permission are required to stream.")
            return
        }
        startPreviewInternal(call)
    }

    private fun startPreviewInternal(call: PluginCall) {
        activity.runOnUiThread {
            try {
                ensureStream()
                if (previewView == null) buildPreviewView()
                // CRITICAL: prepareVideo/prepareAudio MUST run before startPreview —
                // that's what sizes RootEncoder's GL framebuffer. Skipping it makes
                // startPreview throw "FrameBuffer uncompleted (36054)".
                prepareEncoderIfNeeded()
                wantPreview = true
                maybeStartPreview()
                notifyStatus("preview", JSObject())
                call.resolve()
            } catch (e: Exception) {
                reportDiag("startPreview.error", mapOf("error" to (e.message ?: "?")))
                call.reject("startPreview failed: ${e.message}", e)
            }
        }
    }

    /** prepareVideo + prepareAudio — required before startPreview (sizes the GL
     *  framebuffer) and before startStream. Idempotent; re-preparable when not live. */
    private fun prepareEncoderIfNeeded(): Boolean {
        val stream = genericStream ?: return false
        if (prepared) return true
        val okV = stream.prepareVideo(streamW, streamH, targetBitrate, streamFps)
        val okA = stream.prepareAudio(44100, true, 128_000)
        prepared = okV && okA
        if (prepared) { preparedW = streamW; preparedH = streamH; preparedFps = streamFps }
        reportDiag("prepare", mapOf("video" to okV, "audio" to okA, "w" to streamW, "h" to streamH))
        return prepared
    }

    /** Start RootEncoder's preview only when safe: requested, a valid Surface exists,
     *  and it has a non-zero size (else GL framebuffer is incomplete, code 36054).
     *  Idempotent; retried from every surface callback and setPreviewRect. */
    private fun maybeStartPreview() {
        val stream = genericStream ?: return
        val surface = previewView ?: return
        if (!wantPreview) return
        // RootEncoder's own state is the source of truth — avoids my flag desyncing
        // from it and double-starting ("Preview already started" errors).
        if (stream.isOnPreview) { previewStarted = true; return }
        if (previewStarted) return
        val w = surface.width
        val h = surface.height
        val valid = surface.holder.surface?.isValid == true
        if (w <= 0 || h <= 0 || !valid) {
            reportDiag("preview.skip", mapOf("w" to w, "h" to h, "valid" to valid))
            return
        }
        try {
            stream.startPreview(surface)
            previewStarted = true
            try { stream.getGlInterface().setPreviewResolution(w, h) } catch (_: Exception) {}
            reportDiag("preview.ok", mapOf("w" to w, "h" to h))
            // A zOrderOnTop SurfaceView over the WebView doesn't composite its first
            // camera frame until a re-layout forces SurfaceFlinger to update the
            // layer — which is why the preview stayed grey until an interaction (the
            // "scoreboard trick"). Force that re-layout ourselves a few times as the
            // camera spins up.
            kickPreviewRender()
        } catch (e: Exception) {
            // Already-previewing is fine (state converged); anything else we log.
            previewStarted = stream.isOnPreview
            reportDiag("preview.error", mapOf("error" to (e.message ?: "?"), "w" to w, "h" to h))
        }
    }

    /** Force the preview SurfaceView to composite its first camera frame: re-apply
     *  setPreviewResolution + request a layout pass a few times while the camera
     *  spins up. Mirrors what a manual interaction (re-layout) did. */
    private fun kickPreviewRender() {
        val handler = Handler(Looper.getMainLooper())
        for (delay in longArrayOf(250L, 700L, 1500L)) {
            handler.postDelayed({
                val container = previewContainer ?: return@postDelayed
                val lp = container.layoutParams as? FrameLayout.LayoutParams ?: return@postDelayed
                // A plain requestLayout() with an unchanged size doesn't force
                // SurfaceFlinger to recomposite the zOrderOnTop layer (why the camera
                // stayed grey until rotation, esp. when starting already in landscape).
                // A real 1px size nudge fires surfaceChanged -> setPreviewResolution ->
                // composite, exactly like rotating did.
                if (lp.width > 2 && lp.height > 2) {
                    lp.width -= 1
                    container.layoutParams = lp
                    handler.post {
                        lp.width += 1
                        container.layoutParams = lp
                    }
                }
            }, delay)
        }
    }

    /** SurfaceView laid over the WebView. zOrderOnTop so the camera composites ABOVE
     *  the opaque WebView (a default SurfaceView renders behind the window → black). */
    private fun buildPreviewView() {
        val root = activity.window.decorView as ViewGroup
        val container = FrameLayout(context)
        container.setBackgroundColor(Color.BLACK)
        val surface = SurfaceView(context)
        surface.setZOrderOnTop(true)
        container.addView(
            surface,
            FrameLayout.LayoutParams(
                FrameLayout.LayoutParams.MATCH_PARENT,
                FrameLayout.LayoutParams.MATCH_PARENT
            )
        )
        root.addView(container, FrameLayout.LayoutParams(0, 0))
        surface.holder.addCallback(object : SurfaceHolder.Callback {
            override fun surfaceCreated(holder: SurfaceHolder) {
                reportDiag("surface.created")
                maybeStartPreview()
            }
            override fun surfaceChanged(holder: SurfaceHolder, f: Int, w: Int, h: Int) {
                reportDiag("surface.changed", mapOf("w" to w, "h" to h))
                // RootEncoder's example sets the preview resolution here so the GL
                // interface sizes its preview framebuffer to the actual surface.
                if (w > 0 && h > 0) {
                    try { genericStream?.getGlInterface()?.setPreviewResolution(w, h) } catch (_: Exception) {}
                }
                maybeStartPreview()
            }
            override fun surfaceDestroyed(holder: SurfaceHolder) {
                reportDiag("surface.destroyed")
                // Genuine teardown (app background). With off-screen hide this no
                // longer fires during occlusion-guard churn, so it's safe to release
                // RootEncoder's preview for a clean re-start when the surface returns.
                try { genericStream?.let { if (it.isOnPreview) it.stopPreview() } } catch (_: Exception) {}
                previewStarted = false
            }
        })
        previewView = surface
        previewContainer = container
        reportDiag("preview.built")
    }

    @PluginMethod
    fun setPreviewRect(call: PluginCall) {
        val density = context.resources.displayMetrics.density
        val x = call.getFloat("x", 0f)!! * density
        val y = call.getFloat("y", 0f)!! * density
        val w = call.getFloat("width", 0f)!! * density
        val h = call.getFloat("height", 0f)!! * density
        activity.runOnUiThread {
            previewContainer?.let { container ->
                val lp = (container.layoutParams as? FrameLayout.LayoutParams)
                    ?: FrameLayout.LayoutParams(0, 0)
                val hide = w.toInt() <= 0 || h.toInt() <= 0
                if (!hide) {
                    // Show at the requested rect; remember the size.
                    lastPreviewW = w.toInt()
                    lastPreviewH = h.toInt()
                    lp.leftMargin = x.toInt()
                    lp.topMargin = y.toInt()
                    lp.width = lastPreviewW
                    lp.height = lastPreviewH
                } else if (lastPreviewW > 0 && lastPreviewH > 0) {
                    // Hide (occlusion guard): keep the last real SIZE so the surface
                    // stays alive + RootEncoder keeps rendering, but push it fully
                    // off-screen so web dropdowns/dialogs are visible.
                    lp.width = lastPreviewW
                    lp.height = lastPreviewH
                    lp.leftMargin = -(lastPreviewW + 5000)
                    lp.topMargin = 0
                } else {
                    // Never sized yet — nothing to show.
                    lp.width = 0
                    lp.height = 0
                }
                container.layoutParams = lp
            }
            reportDiag("previewRect", mapOf("w" to w.toInt(), "h" to h.toInt(), "hidden" to (w.toInt() <= 0 || h.toInt() <= 0)))
            maybeStartPreview()
            call.resolve()
        }
    }

    // ------------------------------------------------------------------
    // Streaming
    // ------------------------------------------------------------------

    @PluginMethod
    fun startStream(call: PluginCall) {
        val url = call.getString("url")
        val key = call.getString("streamKey")
        if (url == null || key == null) {
            call.reject("url and streamKey are required")
            return
        }
        streamW = call.getInt("width", streamW)!!
        streamH = call.getInt("height", streamH)!!
        streamFps = call.getInt("fps", streamFps)!!
        targetBitrate = call.getInt("bitrate", targetBitrate)!!
        reportDiag("startStream.call", mapOf("w" to streamW, "h" to streamH, "fps" to streamFps, "bitrate" to targetBitrate))

        if (!hasCapturePermissions()) {
            call.reject("Camera and microphone permission are required to stream.")
            return
        }

        activity.runOnUiThread {
            try {
                val stream = ensureStream()
                // RootEncoder forbids prepareVideo while preview/stream is running.
                // The encoder was already prepared for the preview, so:
                //  - same resolution/fps  → just apply the chosen bitrate live.
                //  - different res/fps     → stop preview, re-prepare, restart preview.
                val needReprepare = !prepared ||
                    preparedW != streamW || preparedH != streamH || preparedFps != streamFps
                if (needReprepare) {
                    if (stream.isOnPreview) stream.stopPreview()
                    previewStarted = false
                    val okV = stream.prepareVideo(streamW, streamH, targetBitrate, streamFps)
                    val okA = stream.prepareAudio(44100, true, 128_000)
                    prepared = okV && okA
                    if (prepared) { preparedW = streamW; preparedH = streamH; preparedFps = streamFps }
                    reportDiag("reprepare", mapOf("video" to okV, "audio" to okA, "w" to streamW, "h" to streamH))
                    if (!prepared) {
                        call.reject("Encoder prepare failed (video=$okV audio=$okA)")
                        return@runOnUiThread
                    }
                    maybeStartPreview()
                } else {
                    try { stream.setVideoBitrateOnFly(targetBitrate) } catch (_: Exception) {}
                    reportDiag("bitrate.set", mapOf("bitRate" to targetBitrate))
                }
                // Cap adaptive bitrate at the chosen video+audio target.
                bitrateAdapter.setMaxBitrate(targetBitrate + 128_000)
                val fullUrl = if (url.endsWith("/")) "$url$key" else "$url/$key"
                StreamingForegroundService.start(context)
                stream.startStream(fullUrl)
                startDiagTimer()
                notifyStatus("live", JSObject().put("url", url))
                call.resolve()
            } catch (e: Exception) {
                reportDiag("startStream.error", mapOf("error" to (e.message ?: "?")))
                call.reject("startStream failed: ${e.message}", e)
            }
        }
    }

    @PluginMethod
    fun stopStream(call: PluginCall) {
        activity.runOnUiThread {
            try {
                stopDiagTimer()
                genericStream?.let { if (it.isStreaming) it.stopStream() }
                StreamingForegroundService.stop(context)
                isLive = false
                notifyStatus("idle", JSObject())
                reportDiag("stopStream.ok")
            } catch (e: Exception) {
                // Stopping must never throw up to the UI.
            }
            call.resolve()
        }
    }

    // ------------------------------------------------------------------
    // Stubs — resolve so the shared web bridge never errors. Real RootEncoder
    // implementations land after basic streaming is verified on device.
    // ------------------------------------------------------------------

    @PluginMethod fun setLens(call: PluginCall) {
        call.resolve(JSObject().put("lens", call.getString("lens", "wide")))
    }
    @PluginMethod fun setZoom(call: PluginCall) {
        call.resolve(JSObject().put("factor", call.getFloat("factor", 1f)))
    }
    @PluginMethod fun setMuted(call: PluginCall) {
        call.resolve(JSObject().put("muted", call.getBoolean("muted", false)))
    }
    @PluginMethod fun setFocusExposureLock(call: PluginCall) {
        call.resolve(JSObject().put("locked", call.getBoolean("locked", false)))
    }
    @PluginMethod fun updateOverlay(call: PluginCall) { call.resolve(JSObject().put("ok", true)) }
    @PluginMethod fun setOverlayLayer(call: PluginCall) { call.resolve(JSObject().put("ok", true)) }
    @PluginMethod fun setScreen(call: PluginCall) { call.resolve(JSObject().put("ok", true)) }
    @PluginMethod fun animateScreen(call: PluginCall) { call.resolve(JSObject().put("ok", true)) }
    @PluginMethod fun setOverlay(call: PluginCall) { call.resolve() }
    @PluginMethod fun setBoardOverlay(call: PluginCall) { call.resolve(JSObject().put("ok", true)) }
    @PluginMethod fun setTopOverlay(call: PluginCall) { call.resolve(JSObject().put("ok", true)) }

    // ------------------------------------------------------------------
    // OAuth (Chrome Custom Tabs) — Google login + YouTube connect
    // ------------------------------------------------------------------

    @PluginMethod
    fun startOAuth(call: PluginCall) {
        val url = call.getString("url")
        val scheme = call.getString("callbackScheme")
        if (url == null || scheme == null) {
            call.reject("url and callbackScheme are required")
            return
        }
        // Keep the call alive across the async browser round-trip; resolved in
        // handleOnNewIntent when the server 302s to <scheme>://...
        call.setKeepAlive(true)
        oauthCall = call
        oauthScheme = scheme
        reportDiag("oauth.start", mapOf("scheme" to scheme))
        activity.runOnUiThread {
            try {
                CustomTabsIntent.Builder().build().launchUrl(context, Uri.parse(url))
            } catch (e: Exception) {
                oauthCall = null
                oauthScheme = null
                reportDiag("oauth.error", mapOf("error" to (e.message ?: "?")))
                call.reject("Failed to open sign-in browser: ${e.message}")
            }
        }
    }

    /** Capacitor routes deep-link intents here (MainActivity is singleTask +
     *  registers the pro147auth:// intent-filter). Resolve the pending OAuth call
     *  with the callback URL so nativeStartOAuthRaw gets the temp token. */
    override fun handleOnNewIntent(intent: Intent) {
        super.handleOnNewIntent(intent)
        val data = intent.data ?: return
        val scheme = oauthScheme ?: return
        if (data.scheme == scheme) {
            val call = oauthCall
            oauthCall = null
            oauthScheme = null
            reportDiag("oauth.callback", mapOf("scheme" to scheme))
            call?.resolve(JSObject().put("url", data.toString()))
        }
    }

    // ------------------------------------------------------------------
    // Status / diagnostics
    // ------------------------------------------------------------------

    private fun startDiagTimer() {
        stopDiagTimer()
        diagTimer = Timer()
        diagTimer?.scheduleAtFixedRate(object : TimerTask() {
            override fun run() {
                reportDiag("media.tick", mapOf(
                    "fps" to actualFps,
                    "targetFps" to streamFps,
                    "w" to preparedW,
                    "h" to preparedH,
                    "bitRate" to targetBitrate,
                    "bytesPerSec" to lastBitrate / 8,
                    "connected" to isLive
                ))
            }
        }, 2000, 2000)
    }

    private fun stopDiagTimer() {
        diagTimer?.cancel()
        diagTimer = null
    }

    private fun notifyStatus(state: String, extra: JSObject) {
        extra.put("state", state)
        notifyListeners("status", extra)
    }

    /** Emit an event to JS listeners AND POST it to the server diag log (tagged
     *  platform=android) so the device can be debugged remotely. */
    private fun reportDiag(event: String, extra: Map<String, Any?> = emptyMap()) {
        val obj = JSONObject()
        obj.put("kind", "native-stream-diag")
        obj.put("platform", "android")
        obj.put("tag", diagTag)
        obj.put("event", event)
        obj.put("t", System.currentTimeMillis())
        for ((k, v) in extra) obj.put(k, v)
        try { notifyListeners("status", JSObject.fromJSONObject(obj)) } catch (_: Exception) {}
        if (!diagEnabled) return
        Thread {
            try {
                val conn = URL("https://app.147pro.com/_api/stream-diag").openConnection() as HttpURLConnection
                conn.requestMethod = "POST"
                conn.setRequestProperty("Content-Type", "text/plain")
                conn.connectTimeout = 4000
                conn.readTimeout = 4000
                conn.doOutput = true
                conn.outputStream.use { it.write(obj.toString().toByteArray()) }
                conn.responseCode
                conn.disconnect()
            } catch (_: Exception) {}
        }.start()
    }

    // ------------------------------------------------------------------
    // ConnectChecker (RootEncoder connection lifecycle)
    // ------------------------------------------------------------------

    override fun onConnectionStarted(url: String) { reportDiag("rtmp.started") }

    override fun onConnectionSuccess() {
        isLive = true
        reportDiag("rtmp.success")
        notifyStatus("live", JSObject())
    }

    override fun onConnectionFailed(reason: String) {
        isLive = false
        reportDiag("rtmp.failed", mapOf("reason" to reason))
        notifyStatus("error", JSObject().put("reason", reason))
    }

    override fun onNewBitrate(bitrate: Long) {
        lastBitrate = bitrate
        // Adapt down on congestion (and recover up when it clears) — keeps the
        // pipeline flowing instead of stalling, so preview + fps stay smooth.
        try {
            bitrateAdapter.adaptBitrate(bitrate, genericStream?.getStreamClient()?.hasCongestion() ?: false)
        } catch (_: Exception) {}
    }

    override fun onDisconnect() {
        isLive = false
        reportDiag("rtmp.disconnect")
        notifyStatus("idle", JSObject())
    }

    override fun onAuthError() {
        reportDiag("rtmp.authError")
        notifyStatus("error", JSObject().put("reason", "auth"))
    }

    override fun onAuthSuccess() { reportDiag("rtmp.authSuccess") }
}
