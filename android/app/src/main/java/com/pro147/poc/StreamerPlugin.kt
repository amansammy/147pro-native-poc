package com.pro147.poc

import android.Manifest
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.Color
import android.util.Base64
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
import com.pedro.encoder.input.gl.render.filters.`object`.ImageObjectFilterRender
import com.pedro.encoder.input.sources.audio.MicrophoneSource
import com.pedro.encoder.input.sources.video.Camera2Source
import com.pedro.library.generic.GenericStream
import java.util.Timer
import java.util.TimerTask

/**
 * Android native streaming plugin — the RootEncoder counterpart to the iOS
 * HaishinKit StreamerPlugin. Same JS bridge contract (jsName "Streamer", same
 * methods/events) so the web app drives both platforms with zero web changes.
 *
 * Captures the camera at native resolution, hardware-H.264 encodes, and pushes
 * RTMP(S) directly to YouTube via RootEncoder's GenericStream. Overlays are added
 * as OpenGL image filters; the preview is a SurfaceView positioned over the WebView
 * per setPreviewRect (mirrors the iOS on-top preview).
 *
 * v1 scope: permissions, preview, 1080p60 stream, stop, status ticks, bitrate,
 * lens (front/back), zoom, mute, overlays. OAuth (Custom Tabs), screen slide, and
 * IAP (Play Billing) come next.
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

    // Desired stream config (from startPreview/startStream).
    private var streamW = 1920
    private var streamH = 1080
    private var streamFps = 60
    private var targetBitrate = 9_000_000
    private var usingFrontCamera = false

    private var lastBitrate: Long = 0
    private var isLive = false
    private var diagTimer: Timer? = null

    // Preview rect in device px (converted from web CSS px in setPreviewRect).
    private var previewRect: FloatArray? = null // [x, y, w, h]

    // A pending call held across the runtime permission prompt.
    private var pendingStartCall: PluginCall? = null

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
        usingFrontCamera = (call.getString("lens", "wide") == "front")

        if (!hasCapturePermissions()) {
            // Request camera + mic, then resume in onCapturePermsResult.
            pendingStartCall = call
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
                val stream = ensureStream()
                if (previewView == null) {
                    buildPreviewView()
                }
                if (!stream.isOnPreview) {
                    previewView?.let { stream.startPreview(it) }
                }
                notifyStatus("preview", JSObject())
                call.resolve()
            } catch (e: Exception) {
                call.reject("startPreview failed: ${e.message}", e)
            }
        }
    }

    /** Create the SurfaceView + a container laid over the WebView, hidden until
     *  setPreviewRect gives it a rect. */
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
        // Start zero-sized (hidden) — setPreviewRect positions/sizes it.
        val lp = FrameLayout.LayoutParams(0, 0)
        root.addView(container, lp)
        surface.holder.addCallback(object : SurfaceHolder.Callback {
            override fun surfaceCreated(holder: SurfaceHolder) {}
            override fun surfaceChanged(holder: SurfaceHolder, f: Int, w: Int, h: Int) {}
            override fun surfaceDestroyed(holder: SurfaceHolder) {}
        })
        previewView = surface
        previewContainer = container
    }

    @PluginMethod
    fun setPreviewRect(call: PluginCall) {
        val density = context.resources.displayMetrics.density
        val x = (call.getFloat("x", 0f)!! * density)
        val y = (call.getFloat("y", 0f)!! * density)
        val w = (call.getFloat("width", 0f)!! * density)
        val h = (call.getFloat("height", 0f)!! * density)
        previewRect = floatArrayOf(x, y, w, h)
        activity.runOnUiThread {
            val container = previewContainer
            if (container != null) {
                val lp = container.layoutParams as? FrameLayout.LayoutParams
                    ?: FrameLayout.LayoutParams(0, 0)
                lp.leftMargin = x.toInt()
                lp.topMargin = y.toInt()
                lp.width = w.toInt()
                lp.height = h.toInt()
                container.layoutParams = lp
            }
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
                // Prepare the encoder at the requested resolution/fps/bitrate.
                val okVideo = stream.prepareVideo(
                    width = streamW,
                    height = streamH,
                    bitrate = targetBitrate,
                    fps = streamFps
                )
                val okAudio = stream.prepareAudio(
                    sampleRate = 44100,
                    isStereo = true,
                    bitrate = 128_000
                )
                if (!okVideo || !okAudio) {
                    call.reject("Encoder prepare failed (video=$okVideo audio=$okAudio)")
                    return@runOnUiThread
                }
                // YouTube ingest: full URL = base + "/" + streamKey.
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
                call.resolve()
            } catch (e: Exception) {
                // Stopping should never throw up to the UI.
                call.resolve()
            }
        }
    }

    // ------------------------------------------------------------------
    // Camera controls
    // ------------------------------------------------------------------

    @PluginMethod
    fun setLens(call: PluginCall) {
        val lens = call.getString("lens", "wide")
        activity.runOnUiThread {
            try {
                val wantFront = lens == "front"
                if (wantFront != usingFrontCamera) {
                    genericStream?.switchCamera()
                    usingFrontCamera = wantFront
                }
                // NOTE v1: ultrawide/tele map to the default back (wide) camera.
                // Android multi-camera lens selection is a follow-up.
                call.resolve(JSObject().put("lens", if (usingFrontCamera) "front" else "wide"))
            } catch (e: Exception) {
                call.reject("setLens failed: ${e.message}", e)
            }
        }
    }

    @PluginMethod
    fun setZoom(call: PluginCall) {
        val factor = call.getFloat("factor", 1f)!!
        activity.runOnUiThread {
            try {
                val src = genericStream?.videoSource as? Camera2Source
                src?.setZoom(factor)
                call.resolve(JSObject().put("factor", factor))
            } catch (e: Exception) {
                call.reject("setZoom failed: ${e.message}", e)
            }
        }
    }

    @PluginMethod
    fun setFocusExposureLock(call: PluginCall) {
        // v1: no-op that echoes state (Android focus/exposure lock is a follow-up).
        call.resolve(JSObject().put("locked", call.getBoolean("locked", false)))
    }

    @PluginMethod
    fun setMuted(call: PluginCall) {
        val muted = call.getBoolean("muted", false)!!
        activity.runOnUiThread {
            try {
                val mic = genericStream?.audioSource as? MicrophoneSource
                if (muted) mic?.mute() else mic?.unMute()
                call.resolve(JSObject().put("muted", muted))
            } catch (e: Exception) {
                call.reject("setMuted failed: ${e.message}", e)
            }
        }
    }

    // ------------------------------------------------------------------
    // Overlays (OpenGL image filters)
    // ------------------------------------------------------------------
    // v1: full-frame overlay via updateOverlay + positioned layers via
    // setOverlayLayer. HaishinKit-style content-sized layers map to
    // ImageObjectFilterRender with percentage position/scale relative to the frame.

    @PluginMethod
    fun updateOverlay(call: PluginCall) {
        val image = call.getString("image")
        if (image == null) { call.resolve(JSObject().put("ok", false)); return }
        activity.runOnUiThread {
            try {
                val bmp = decodeImage(image)
                if (bmp != null) {
                    val render = ImageObjectFilterRender()
                    render.setImage(bmp)
                    render.setScale(100f, 100f)
                    render.setPosition(0f, 0f)
                    genericStream?.getGlInterface()?.setFilter(0, render)
                }
                call.resolve(JSObject().put("ok", true))
            } catch (e: Exception) {
                call.resolve(JSObject().put("ok", false))
            }
        }
    }

    @PluginMethod
    fun setOverlayLayer(call: PluginCall) {
        val slot = call.getString("slot") ?: "board"
        val image = call.getString("image") ?: ""
        val x = call.getFloat("x", 0f)!!
        val y = call.getFloat("y", 0f)!!
        activity.runOnUiThread {
            try {
                val gl = genericStream?.getGlInterface()
                val idx = slotIndex(slot)
                if (image.isEmpty()) {
                    // Clear this slot with a 1x1 transparent image.
                    gl?.setFilter(idx, ImageObjectFilterRender())
                } else {
                    val bmp = decodeImage(image)
                    if (bmp != null) {
                        val render = ImageObjectFilterRender()
                        render.setImage(bmp)
                        // Convert absolute (x,y)+size (authored at streamW×streamH) to
                        // percentages the GL filter expects.
                        val wPct = bmp.width * 100f / streamW
                        val hPct = bmp.height * 100f / streamH
                        val xPct = x * 100f / streamW
                        val yPct = y * 100f / streamH
                        render.setScale(wPct, hPct)
                        render.setPosition(xPct, yPct)
                        gl?.setFilter(idx, render)
                    }
                }
                call.resolve(JSObject().put("ok", true))
            } catch (e: Exception) {
                call.resolve(JSObject().put("ok", false))
            }
        }
    }

    // Fixed filter slots → keep z-order stable (board under, sponsor/watermark over).
    private fun slotIndex(slot: String): Int = when (slot) {
        "board" -> 0
        "screen" -> 1
        "sponsor" -> 2
        "watermark" -> 3
        else -> 0
    }

    @PluginMethod
    fun setScreen(call: PluginCall) {
        val image = call.getString("image") ?: ""
        activity.runOnUiThread {
            val gl = genericStream?.getGlInterface()
            try {
                if (image.isEmpty()) {
                    gl?.setFilter(slotIndex("screen"), ImageObjectFilterRender())
                } else {
                    val bmp = decodeImage(image)
                    if (bmp != null) {
                        val render = ImageObjectFilterRender()
                        render.setImage(bmp)
                        render.setScale(100f, 100f)
                        render.setPosition(0f, 0f)
                        gl?.setFilter(slotIndex("screen"), render)
                    }
                }
                call.resolve(JSObject().put("ok", true))
            } catch (e: Exception) {
                call.resolve(JSObject().put("ok", false))
            }
        }
    }

    @PluginMethod
    fun animateScreen(call: PluginCall) {
        // v1: no native slide yet — the JS screen manager can fall back to
        // set/clear. Resolve so callers don't error.
        call.resolve(JSObject().put("ok", true))
    }

    // Legacy/no-op contract methods (kept so the JS bridge never rejects).
    @PluginMethod fun setOverlay(call: PluginCall) { call.resolve() }
    @PluginMethod fun setBoardOverlay(call: PluginCall) { forwardLayer(call, "board") }
    @PluginMethod fun setTopOverlay(call: PluginCall) { forwardLayer(call, "sponsor") }

    private fun forwardLayer(call: PluginCall, slot: String) {
        val image = call.getString("image") ?: ""
        activity.runOnUiThread {
            try {
                val bmp = if (image.isEmpty()) null else decodeImage(image)
                val render = ImageObjectFilterRender()
                if (bmp != null) { render.setImage(bmp); render.setScale(100f, 100f); render.setPosition(0f, 0f) }
                genericStream?.getGlInterface()?.setFilter(slotIndex(slot), render)
                call.resolve(JSObject().put("ok", true))
            } catch (e: Exception) {
                call.resolve(JSObject().put("ok", false))
            }
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
        // RootEncoder can retry via getStreamClient().reTry(...); v1 surfaces the
        // failure and lets the JS decide. Reconnect logic is a follow-up.
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

    // ------------------------------------------------------------------
    // Utils
    // ------------------------------------------------------------------

    /** Decode a base64 or data: URL PNG/JPEG into a Bitmap. */
    private fun decodeImage(image: String): Bitmap? {
        return try {
            val base64 = if (image.contains(",")) image.substringAfter(",") else image
            val bytes = Base64.decode(base64, Base64.DEFAULT)
            BitmapFactory.decodeByteArray(bytes, 0, bytes.size)
        } catch (e: Exception) {
            null
        }
    }
}
