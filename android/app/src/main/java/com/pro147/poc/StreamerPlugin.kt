package com.pro147.poc

import android.Manifest
import android.graphics.Color
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
import com.pedro.common.ConnectChecker
import com.pedro.library.generic.GenericStream
import java.util.Timer
import java.util.TimerTask

/**
 * Android native streaming plugin — the RootEncoder counterpart to the iOS
 * HaishinKit StreamerPlugin. Same JS bridge contract (jsName "Streamer", same
 * methods/events) so the web app drives both platforms with zero web changes.
 *
 * v1 = the VERIFIED core (against RootEncoder 2.6.1): permissions, preview,
 * 1080p60 H.264 → RTMP(S), stop, connection lifecycle, and media.tick status
 * events. Overlays, zoom, mute, and lens switching are stubbed no-ops for now —
 * their RootEncoder APIs are added next, once basic streaming is confirmed on the
 * Nord 3. The stubs still resolve() so the shared web bridge never errors.
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

    private var streamW = 1920
    private var streamH = 1080
    private var streamFps = 60
    private var targetBitrate = 9_000_000

    private var lastBitrate: Long = 0
    private var isLive = false
    private var diagTimer: Timer? = null

    // ------------------------------------------------------------------
    // Lifecycle helpers
    // ------------------------------------------------------------------

    private fun ensureStream(): GenericStream {
        genericStream?.let { return it }
        val s = GenericStream(context, this).apply {
            getGlInterface().autoHandleOrientation = true
        }
        genericStream = s
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
        streamW = call.getInt("width", 1920)!!
        streamH = call.getInt("height", 1080)!!
        streamFps = call.getInt("fps", 60)!!

        if (!hasCapturePermissions()) {
            requestAllPermissions(call, "onCapturePermsResult")
            return
        }
        startPreviewInternal(call)
    }

    @PermissionCallback
    private fun onCapturePermsResult(call: PluginCall) {
        if (!hasCapturePermissions()) {
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
                // Don't start the GL preview yet — the SurfaceView is still 0×0 until
                // setPreviewRect sizes it. Starting RootEncoder's preview on a zero /
                // not-yet-created surface throws "FrameBuffer uncompleted (36054)".
                // maybeStartPreview() runs it once the surface is created AND sized,
                // driven by the SurfaceHolder callbacks + setPreviewRect.
                wantPreview = true
                maybeStartPreview()
                notifyStatus("preview", JSObject())
                call.resolve()
            } catch (e: Exception) {
                call.reject("startPreview failed: ${e.message}", e)
            }
        }
    }

    /** Start RootEncoder's preview only when it's safe: preview requested, a valid
     *  Surface exists, and it has a non-zero size (else GL framebuffer is incomplete).
     *  Idempotent + retried from every surface callback and setPreviewRect. */
    private fun maybeStartPreview() {
        val stream = genericStream ?: return
        val surface = previewView ?: return
        if (!wantPreview || previewStarted) return
        if (surface.width <= 0 || surface.height <= 0) return
        val holder = surface.holder
        if (holder.surface == null || !holder.surface.isValid) return
        try {
            stream.startPreview(surface)
            previewStarted = true
        } catch (e: Exception) {
            // Leave previewStarted=false; will retry on the next surfaceChanged.
        }
    }

    /** SurfaceView in a container laid over the WebView; zero-sized until
     *  setPreviewRect positions it. */
    private fun buildPreviewView() {
        val root = activity.window.decorView as ViewGroup
        val container = FrameLayout(context)
        container.setBackgroundColor(Color.BLACK)
        val surface = SurfaceView(context)
        container.addView(
            surface,
            FrameLayout.LayoutParams(
                FrameLayout.LayoutParams.MATCH_PARENT,
                FrameLayout.LayoutParams.MATCH_PARENT
            )
        )
        root.addView(container, FrameLayout.LayoutParams(0, 0))
        surface.holder.addCallback(object : SurfaceHolder.Callback {
            override fun surfaceCreated(holder: SurfaceHolder) { maybeStartPreview() }
            override fun surfaceChanged(holder: SurfaceHolder, f: Int, w: Int, h: Int) {
                maybeStartPreview()
            }
            override fun surfaceDestroyed(holder: SurfaceHolder) {
                // Surface gone (e.g. rotation / background) — allow a clean re-start.
                previewStarted = false
            }
        })
        previewView = surface
        previewContainer = container
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
                lp.leftMargin = x.toInt()
                lp.topMargin = y.toInt()
                lp.width = w.toInt()
                lp.height = h.toInt()
                container.layoutParams = lp
            }
            // Now that the preview has a real size, the surface can create its GL
            // framebuffer — start the preview if it was waiting on a size.
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

        if (!hasCapturePermissions()) {
            call.reject("Camera and microphone permission are required to stream.")
            return
        }

        activity.runOnUiThread {
            try {
                val stream = ensureStream()
                // Positional args (width, height, bitrate, fps) — 4th param is fps.
                val okVideo = stream.prepareVideo(streamW, streamH, targetBitrate, streamFps)
                val okAudio = stream.prepareAudio(44100, true, 128_000)
                if (!okVideo || !okAudio) {
                    call.reject("Encoder prepare failed (video=$okVideo audio=$okAudio)")
                    return@runOnUiThread
                }
                val fullUrl = if (url.endsWith("/")) "$url$key" else "$url/$key"
                StreamingForegroundService.start(context)
                stream.startStream(fullUrl)
                startDiagTimer()
                notifyStatus("live", JSObject().put("url", url))
                call.resolve()
            } catch (e: Exception) {
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
            } catch (e: Exception) {
                // Stopping must never throw up to the UI.
            }
            call.resolve()
        }
    }

    // ------------------------------------------------------------------
    // Stubs — resolve so the shared web bridge never errors. Real RootEncoder
    // implementations (overlays via ImageObjectFilterRender, zoom via
    // Camera2Source, mute via the audio source, lens via switchCamera) land after
    // basic streaming is verified on device.
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
    // Status / diagnostics
    // ------------------------------------------------------------------

    private fun startDiagTimer() {
        stopDiagTimer()
        diagTimer = Timer()
        diagTimer?.scheduleAtFixedRate(object : TimerTask() {
            override fun run() {
                val data = JSObject()
                    .put("event", "media.tick")
                    .put("kind", "native-stream-diag")
                    .put("fps", streamFps)
                    .put("bitRate", targetBitrate)
                    .put("bytesPerSec", lastBitrate / 8)
                    .put("connected", isLive)
                notifyListeners("status", data)
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

    // ------------------------------------------------------------------
    // ConnectChecker (RootEncoder connection lifecycle)
    // ------------------------------------------------------------------

    override fun onConnectionStarted(url: String) {}

    override fun onConnectionSuccess() {
        isLive = true
        notifyStatus("live", JSObject())
    }

    override fun onConnectionFailed(reason: String) {
        isLive = false
        notifyStatus("error", JSObject().put("reason", reason))
    }

    override fun onNewBitrate(bitrate: Long) {
        lastBitrate = bitrate
    }

    override fun onDisconnect() {
        isLive = false
        notifyStatus("idle", JSObject())
    }

    override fun onAuthError() {
        notifyStatus("error", JSObject().put("reason", "auth"))
    }

    override fun onAuthSuccess() {}
}
