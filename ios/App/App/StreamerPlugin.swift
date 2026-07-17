import Foundation
import Capacitor
import HaishinKit
import AVFoundation
import VideoToolbox
import UIKit
import AuthenticationServices

/// Native streaming plugin for the 147 Pro PoC.
///
/// Captures the camera at true native resolution via AVFoundation (which the
/// WebKit `getUserMedia` sandbox can't expose), hardware H.264 encodes, and
/// pushes RTMP directly to YouTube — no MediaMTX, no WebRTC ceilings.
///
/// Written against **HaishinKit 2.0.9** (latest on CocoaPods trunk). Confirmed
/// working: true 1080p60 → YouTube with a live overlay. This build adds
/// thermal-adaptive bitrate, auto-reconnect, zoom, focus/exposure lock, and a
/// clean stop/start teardown.
@objc(StreamerPlugin)
public class StreamerPlugin: CAPPlugin, CAPBridgedPlugin {
    public let identifier = "StreamerPlugin"
    public let jsName = "Streamer"
    public let pluginMethods: [CAPPluginMethod] = [
        CAPPluginMethod(name: "startPreview", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "startStream", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "stopStream", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "setLens", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "setOverlay", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "updateOverlay", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "setBoardOverlay", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "setTopOverlay", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "setOverlayLayer", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "setScreen", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "animateScreen", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "setZoom", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "setFocusExposureLock", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "setPreviewRect", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "setMuted", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "startOAuth", returnType: CAPPluginReturnPromise)
    ]

    // Retained so the auth session isn't deallocated mid-flow.
    private var authSession: ASWebAuthenticationSession?

    // Scoreboard overlays composited on the HaishinKit screen (appear in both the
    // native preview and the encoded stream). @ScreenActor-isolated.
    // - scoreboard: legacy plain-text placeholder (unused; kept for compatibility).
    // - overlayImage: legacy single full-frame overlay (unused now; the layered
    //   board/screen/top objects below replaced it).
    @ScreenActor private var scoreboard: TextScreenObject?
    @ScreenActor private var overlayImage: ImageScreenObject?

    // CONTENT-SIZED overlay layers, pre-created in z-order:
    //   camera → board → screen → sponsor → watermark
    // Each layer receives a SMALL bitmap (just its element — scoreboard strip, logo
    // box) positioned at (x,y). HaishinKit's CPU compositor blends each layer at its
    // NATURAL pixel size, so small layers cost a fraction of a full-frame overlay per
    // frame — the fix for the CPU blend cooking 1080p60. The screen takeover is
    // full-frame (only when active) and slides natively via layoutMargin.
    @ScreenActor private var boardLayer: ImageScreenObject?
    @ScreenActor private var sponsorLayer: ImageScreenObject?
    @ScreenActor private var watermarkLayer: ImageScreenObject?
    @ScreenActor private var screenLayer: ImageScreenObject?
    @ScreenActor private var overlayLayersReady = false
    private var screenSlideTask: Task<Void, Never>?
    private var screenSlideHeight: CGFloat = 1080

    private let mixer = MediaMixer(
        multiCamSessionEnabled: false,
        multiTrackAudioMixingEnabled: false,
        useManualCapture: false
    )
    private var connection: RTMPConnection?
    private var stream: RTMPStream?
    private var previewView: MTHKView?
    // A clipping wrapper around the MTHKView — cornerRadius on a Metal view
    // (MTHKView) doesn't clip its drawable, so we round the CONTAINER instead.
    private var previewContainer: UIView?
    // Where the web wants the camera preview drawn (CSS px == UIKit points, in
    // web-viewport coords). The preview view is placed ON TOP of the WebView at
    // this rect so it shows inside the app's preview box (the camera renders on
    // a WKWebView so it can't be revealed by making the DOM transparent). A zero
    // rect hides it.
    private var previewRect: CGRect?
    private var currentLens = "wide"
    private var currentDevice: AVCaptureDevice?
    private var observersStarted = false
    // Live camera orientation. The phone can be held in EITHER landscape; we read
    // the INTERFACE orientation (the app supports both landscapes, so the UI
    // follows the device and this is valid immediately) and re-orient capture so
    // the video stays upright both ways (fixes upside-down with power button down).
    private var lastVideoOrientation: AVCaptureVideoOrientation = .landscapeRight
    private var videoOrientationApplied = false

    // Stream params retained for auto-reconnect + thermal-adaptive bitrate.
    private var streamURL: String?
    private var streamKey: String?
    private var streamW = 1920
    private var streamH = 1080
    private var streamFps: Double = 60
    private var targetBitrate = 12_000_000
    private var appliedBitrate = 0
    private var userStopped = false
    private var reconnecting = false
    private var overlayDiagCounter = 0
    // The real app's React effects call startPreview repeatedly (~4x/sec); doing a
    // FULL capture re-setup on each thrashes the camera and starves the encoder.
    // So the CAPTURE session (preset/camera/mic/orientation/fps) is configured
    // once (or when the resolution changes). Everything else in setupPipeline
    // (offscreen mode, RTMP objects, preview attach) stays club-identical and is
    // idempotent on repeat, so churn becomes cheap no-ops.
    private var captureConfigured = false
    private var configuredWidth = 0
    private var configuredHeight = 0
    // Applied capture frame rate. Tracked separately from the capture guard (which
    // only keys on resolution) so an fps change (e.g. picking 1080p60 after the
    // preview already started at 30) actually re-applies.
    private var configuredFps: Double = 0

    // MARK: - JS API

    @objc func startPreview(_ call: CAPPluginCall) {
        let width = call.getInt("width") ?? 1920
        let height = call.getInt("height") ?? 1080
        let fps = Double(call.getInt("fps") ?? 60)
        if let lens = call.getString("lens") { currentLens = lens }
        Task {
            do {
                try await self.setupPipeline(width: width, height: height, fps: fps)
                self.emit(["state": "preview", "width": width, "height": height, "fps": Int(fps), "lens": self.currentLens])
                call.resolve()
            } catch {
                self.reportDiag("startPreview.error", ["error": error.localizedDescription, "errorFull": "\(error)"])
                call.reject("startPreview failed: \(error.localizedDescription)")
            }
        }
    }

    @objc func startStream(_ call: CAPPluginCall) {
        guard let url = call.getString("url"),
              let streamKey = call.getString("streamKey") else {
            call.reject("url and streamKey are required")
            return
        }
        let width = call.getInt("width") ?? 1920
        let height = call.getInt("height") ?? 1080
        let fps = Double(call.getInt("fps") ?? 60)
        let bitrate = call.getInt("bitrate") ?? 12_000_000
        // Retain for reconnect + thermal adaptation.
        self.streamURL = url
        self.streamKey = streamKey
        self.streamW = width; self.streamH = height; self.streamFps = fps
        self.targetBitrate = bitrate; self.appliedBitrate = bitrate
        self.userStopped = false
        self.reconnecting = false
        Task {
            do {
                // PROVEN club pipeline: full capture setup + DIRECT go-live. The
                // retry/idempotency/offscreen-toggle/mixer-preview experiments
                // regressed the framerate (60 → 0/11 fps); this is restored to the
                // exact path that streamed true 1080p60 to YouTube at the club.
                try await self.setupPipeline(width: width, height: height, fps: fps)
                try await self.goLive()
                self.emit(["state": "live", "width": width, "height": height, "fps": Int(fps), "bitrate": bitrate])
                call.resolve()
            } catch {
                self.reportDiag("startStream.error", ["error": error.localizedDescription, "errorFull": "\(error)"])
                call.reject("startStream failed: \(error.localizedDescription)")
            }
        }
    }

    /// Apply encoder settings, start observers, connect + publish. Reused by both
    /// startStream and auto-reconnect.
    private func goLive() async throws {
        guard let connection = self.connection, let stream = self.stream,
              let url = self.streamURL, let key = self.streamKey else {
            throw NSError(domain: "Streamer", code: 1, userInfo: [NSLocalizedDescriptionKey: "pipeline not ready"])
        }
        self.reportDiag("perms", [
            "camera": "\(AVCaptureDevice.authorizationStatus(for: .video).rawValue)",
            "mic": "\(AVCaptureDevice.authorizationStatus(for: .audio).rawValue)"
        ])
        var videoSettings = await stream.videoSettings
        videoSettings.videoSize = CGSize(width: streamW, height: streamH)
        videoSettings.bitRate = targetBitrate
        // High + AutoLevel: Baseline 3.1 (the default) caps at 720p and emits ZERO
        // frames at 1080p; High/AutoLevel lets VideoToolbox pick the level 1080p60
        // needs and is the quality tier we want.
        videoSettings.profileLevel = kVTProfileLevel_H264_High_AutoLevel as String
        await stream.setVideoSettings(videoSettings)
        self.appliedBitrate = targetBitrate
        self.reportDiag("videoSettings.applied", ["w": streamW, "h": streamH, "bitRate": targetBitrate, "profile": "H264_High_AutoLevel"])

        self.startObservers()

        self.reportDiag("connect.attempt", ["url": url])
        _ = try await connection.connect(url)
        self.reportDiag("connect.ok", ["connected": await connection.connected])

        self.reportDiag("publish.attempt", ["keyPrefix": String(key.prefix(4)) + "…"])
        _ = try await stream.publish(key)
        self.reportDiag("publish.ok", ["readyState": "\(await stream.readyState)"])
    }

    @objc func stopStream(_ call: CAPPluginCall) {
        Task {
            self.userStopped = true // breaks any in-flight reconnect loop
            await self.teardownStreamObjects()
            self.emit(["state": "idle"])
            call.resolve()
        }
    }

    /// Close + release the RTMP objects so the next start is FRESH. Reusing a
    /// closed RTMPConnection/RTMPStream (the old behaviour) produced a zombie
    /// "publishing" stream with 0 fps / 0 KB/s. The mixer, camera, preview, and
    /// overlay stay alive.
    private func teardownStreamObjects() async {
        if let stream = self.stream {
            _ = try? await stream.close()
            await mixer.removeOutput(stream)
        }
        if let connection = self.connection {
            _ = try? await connection.close()
        }
        self.connection = nil
        self.stream = nil
        self.observersStarted = false
    }

    // MARK: - Overlay

    @objc func setOverlay(_ call: CAPPluginCall) {
        let text = call.getString("text") ?? ""
        Task {
            await self.updateScoreboard(text)
            self.reportDiag("overlay.set", ["text": text])
            call.resolve()
        }
    }

    /// Content-sized overlay layer: slot ∈ "board"|"sponsor"|"watermark", a SMALL
    /// bitmap positioned at (x,y) in composite px. This is the production path.
    /// The PNG is decoded on a BACKGROUND thread (this Task), NOT on the @ScreenActor
    /// — decoding on the compositor actor blocked it every update (pool clock /
    /// crossfade / screen), starving the composite and dropping frames.
    @objc func setOverlayLayer(_ call: CAPPluginCall) {
        let slot = call.getString("slot") ?? "board"
        let img = call.getString("image") ?? ""
        let x = CGFloat(call.getDouble("x") ?? 0)
        let y = CGFloat(call.getDouble("y") ?? 0)
        Task.detached { [weak self] in
            guard let self else { return }
            let cg = img.isEmpty ? nil : self.decodeCGImage(img)
            await self.setLayerImage(slot, cg, img.isEmpty, x, y)
            call.resolve(["ok": true])
        }
    }

    // Legacy full-frame entry points — route to the board slot at origin so an old
    // caller still shows something; new JS uses setOverlayLayer.
    @objc func updateOverlay(_ call: CAPPluginCall) {
        let img = call.getString("image") ?? ""
        Task.detached { [weak self] in
            guard let self else { return }
            let cg = img.isEmpty ? nil : self.decodeCGImage(img)
            await self.setLayerImage("board", cg, img.isEmpty, 0, 0)
            call.resolve(["ok": true])
        }
    }
    @objc func setBoardOverlay(_ call: CAPPluginCall) {
        let img = call.getString("image") ?? ""
        Task.detached { [weak self] in
            guard let self else { return }
            let cg = img.isEmpty ? nil : self.decodeCGImage(img)
            await self.setLayerImage("board", cg, img.isEmpty, 0, 0)
            call.resolve(["ok": true])
        }
    }
    @objc func setTopOverlay(_ call: CAPPluginCall) {
        call.resolve(["ok": true])
    }

    /// Set (or clear) the full-frame screen takeover image. Decoded off the
    /// compositor actor (full-frame decode blocking it was the screen-toggle stutter).
    @objc func setScreen(_ call: CAPPluginCall) {
        let img = call.getString("image") ?? ""
        Task.detached { [weak self] in
            guard let self else { return }
            let cg = img.isEmpty ? nil : self.decodeCGImage(img)
            await self.setScreenImage(cg, img.isEmpty)
            call.resolve(["ok": true])
        }
    }

    /// Slide the screen layer natively (no per-frame PNG): "in" from the top,
    /// "out" to the bottom. Driven by a ~60fps task moving layoutMargin.top.
    @objc func animateScreen(_ call: CAPPluginCall) {
        let dir = call.getString("dir") ?? "in"
        let durationMs = call.getDouble("durationMs") ?? 450
        self.startScreenSlide(dir: dir, durationMs: durationMs)
        call.resolve(["ok": true])
    }

    /// Pre-create the layers in fixed z-order so board sits under the screen and
    /// sponsor+watermark over it: camera → board → screen → sponsor → watermark.
    @ScreenActor
    private func ensureOverlayLayers() {
        guard !overlayLayersReady else { return }
        func make() -> ImageScreenObject {
            let o = ImageScreenObject()
            o.horizontalAlignment = .left
            o.verticalAlignment = .top
            o.isVisible = false
            try? mixer.screen.addChild(o)
            return o
        }
        boardLayer = make()      // bottom
        screenLayer = make()     // over board (full-frame takeover)
        sponsorLayer = make()    // over screen
        watermarkLayer = make()  // top
        overlayLayersReady = true
    }

    private func decodeCGImage(_ b64: String) -> CGImage? {
        let parts = b64.components(separatedBy: ",")
        let raw = parts.count > 1 ? parts[parts.count - 1] : b64
        guard let data = Data(base64Encoded: raw, options: .ignoreUnknownCharacters),
              let image = UIImage(data: data) else { return nil }
        return image.cgImage
    }

    /// Actor-side setter — takes an ALREADY-decoded image so the only work on the
    /// compositor actor is the cheap cgImage/layout assignment (no PNG decode).
    @ScreenActor
    private func setLayerImage(_ slot: String, _ cg: CGImage?, _ clear: Bool, _ x: CGFloat, _ y: CGFloat) {
        ensureOverlayLayers()
        let layer: ImageScreenObject?
        switch slot {
        case "sponsor": layer = sponsorLayer
        case "watermark": layer = watermarkLayer
        default: layer = boardLayer
        }
        guard let layer else { return }
        if clear || cg == nil {
            layer.isVisible = false
            layer.cgImage = nil
            return
        }
        layer.layoutMargin = .init(top: y, left: x, bottom: 0, right: 0)
        layer.cgImage = cg
        layer.invalidateLayout()
        layer.isVisible = true
    }

    @ScreenActor
    private func setScreenImage(_ cg: CGImage?, _ clear: Bool) {
        ensureOverlayLayers()
        if clear || cg == nil {
            screenLayer?.isVisible = false
            screenLayer?.cgImage = nil
            return
        }
        screenLayer?.cgImage = cg
        // Visibility + position handled by animateScreen.
    }

    // MARK: - Native screen slide

    private func startScreenSlide(dir: String, durationMs: Double) {
        screenSlideTask?.cancel()
        let h = screenSlideHeight
        let startY: CGFloat = dir == "in" ? -h : 0
        let endY: CGFloat = dir == "in" ? 0 : h
        let dur = max(0.05, durationMs / 1000.0)
        let started = Date()
        screenSlideTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                let elapsed = Date().timeIntervalSince(started)
                let p = min(1.0, elapsed / dur)
                let e = 1 - pow(1 - p, 3) // easeOutCubic
                let y = startY + (endY - startY) * CGFloat(e)
                await self.setScreenSlideOffset(y)
                if p >= 1 { break }
                // ~20fps (was 60): each slide frame RE-COMPOSITES the full-frame
                // screen on the CPU, so 60fps for 450ms was a big heat burst on
                // every toggle. 20fps still reads as a slide at a third of the cost.
                try? await Task.sleep(nanoseconds: 50_000_000)
            }
            if dir == "out" {
                await self.hideScreenLayer()
            }
        }
    }

    @ScreenActor
    private func setScreenSlideOffset(_ y: CGFloat) {
        screenLayer?.isVisible = true
        screenLayer?.layoutMargin = .init(top: y, left: 0, bottom: 0, right: 0)
        // Mutating layoutMargin does NOT flag a re-layout on its own (only size /
        // cgImage / invalidateLayout do), so without this the bounds stay stale and
        // the image pops instead of sliding.
        screenLayer?.invalidateLayout()
    }

    @ScreenActor
    private func hideScreenLayer() {
        screenLayer?.isVisible = false
        screenLayer?.cgImage = nil
        screenLayer?.layoutMargin = .init(top: 0, left: 0, bottom: 0, right: 0)
    }

    @ScreenActor
    private func applyOverlayImage(_ b64: String) -> Bool {
        // Accept a raw base64 or a data: URL.
        let parts = b64.components(separatedBy: ",")
        let raw = parts.count > 1 ? parts[parts.count - 1] : b64
        guard let data = Data(base64Encoded: raw, options: .ignoreUnknownCharacters),
              let image = UIImage(data: data),
              let cg = image.cgImage else { return false }
        if overlayImage == nil {
            let obj = ImageScreenObject()
            obj.horizontalAlignment = .left   // full-frame image, top-left, drawn 1:1
            obj.verticalAlignment = .top
            try? mixer.screen.addChild(obj)
            overlayImage = obj
            // Drop the plain-text placeholder once the real board is in.
            if let sb = scoreboard {
                mixer.screen.removeChild(sb)
                scoreboard = nil
            }
        }
        overlayImage?.cgImage = cg
        // Periodically report the overlay's live geometry so we can see on-device
        // whether it's actually in the composite with valid bounds (the scoreboard
        // renders into the same buffer the encoder sends AND the preview shows).
        overlayDiagCounter += 1
        if overlayDiagCounter % 8 == 1 {
            let b = overlayImage?.bounds ?? .zero
            let vis = overlayImage?.isVisible ?? false
            let ss = mixer.screen.size
            reportDiag("overlay.geom", [
                "boundsW": Double(b.width), "boundsH": Double(b.height),
                "boundsX": Double(b.origin.x), "boundsY": Double(b.origin.y),
                "visible": vis,
                "screenW": Double(ss.width), "screenH": Double(ss.height)
            ])
        }
        return true
    }

    @ScreenActor
    private func updateScoreboard(_ text: String) {
        if scoreboard == nil {
            let t = TextScreenObject()
            t.horizontalAlignment = .center
            t.verticalAlignment = .top
            t.layoutMargin = .init(top: 48, left: 0, bottom: 0, right: 0)
            t.attributes = [
                .font: UIFont.boldSystemFont(ofSize: 72),
                .foregroundColor: UIColor.white,
                .strokeColor: UIColor.black,
                .strokeWidth: -4.0
            ]
            try? mixer.screen.addChild(t)
            scoreboard = t
        }
        scoreboard?.string = text
    }

    // MARK: - Camera controls

    /// Live camera-lens switch. Back lenses: "wide" (1x), "ultrawide" (0.5x),
    /// "tele" (3x); plus "front". These ARE the optical lenses (true optical steps).
    @objc func setLens(_ call: CAPPluginCall) {
        let lens = call.getString("lens") ?? "wide"
        Task {
            guard let device = self.cameraDevice(for: lens) else {
                self.reportDiag("lens.unavailable", ["lens": lens])
                call.reject("lens '\(lens)' not available on this device")
                return
            }
            do {
                try await self.mixer.attachVideo(device, track: 0)
                self.currentLens = lens
                self.currentDevice = device
                self.reportDiag("lens.set", ["lens": lens, "device": device.localizedName])
                self.emit(["state": "lens", "lens": lens])
                call.resolve(["lens": lens])
            } catch {
                self.reportDiag("lens.error", ["lens": lens, "error": error.localizedDescription])
                call.reject("lens switch failed: \(error.localizedDescription)")
            }
        }
    }

    /// Zoom the current lens. factor 1.0 = the lens's native field of view; higher
    /// crops in (digital past the optical range). Combine with setLens for the
    /// optical steps.
    @objc func setZoom(_ call: CAPPluginCall) {
        let factor = call.getDouble("factor") ?? 1.0
        guard let device = self.currentDevice else {
            call.reject("no active camera")
            return
        }
        do {
            try device.lockForConfiguration()
            let maxZoom = min(device.maxAvailableVideoZoomFactor, 10.0)
            let clamped = max(1.0, min(CGFloat(factor), maxZoom))
            device.videoZoomFactor = clamped
            device.unlockForConfiguration()
            self.reportDiag("zoom.set", ["factor": Double(clamped)])
            call.resolve(["factor": Double(clamped)])
        } catch {
            self.reportDiag("zoom.error", ["error": error.localizedDescription])
            call.reject("zoom failed: \(error.localizedDescription)")
        }
    }

    /// Lock (or restore auto) focus + exposure — useful for a fixed table shot so
    /// the camera doesn't hunt when players move.
    @objc func setFocusExposureLock(_ call: CAPPluginCall) {
        let locked = call.getBool("locked") ?? true
        guard let device = self.currentDevice else {
            call.reject("no active camera")
            return
        }
        do {
            try device.lockForConfiguration()
            if locked {
                if device.isFocusModeSupported(.locked) { device.focusMode = .locked }
                if device.isExposureModeSupported(.locked) { device.exposureMode = .locked }
            } else {
                if device.isFocusModeSupported(.continuousAutoFocus) { device.focusMode = .continuousAutoFocus }
                if device.isExposureModeSupported(.continuousAutoExposure) { device.exposureMode = .continuousAutoExposure }
            }
            device.unlockForConfiguration()
            self.reportDiag("focusExposure.set", ["locked": locked])
            call.resolve(["locked": locked])
        } catch {
            self.reportDiag("focusExposure.error", ["error": error.localizedDescription])
            call.reject("focus/exposure lock failed: \(error.localizedDescription)")
        }
    }

    /// Mute/unmute the microphone in the encoded stream. Uses the audio mixer's
    /// isMuted flag (keeps the mic attached — no track drop/glitch), so YouTube
    /// gets silence while muted and audio resumes cleanly on unmute.
    @objc func setMuted(_ call: CAPPluginCall) {
        let muted = call.getBool("muted") ?? false
        Task {
            var settings = await mixer.audioMixerSettings
            settings.isMuted = muted
            await mixer.setAudioMixerSettings(settings)
            self.reportDiag("audio.muted", ["muted": muted])
            call.resolve(["muted": muted])
        }
    }

    // MARK: - Orientation

    /// The capture orientation for the current INTERFACE orientation. Apple's
    /// authoritative direct mapping (see the AVCam sample): interface and capture
    /// use the same physical convention, so no inversion. Immediately valid
    /// (unlike UIDevice.orientation, which is `.unknown` until motion updates run
    /// and stays stale if the phone doesn't move — that's why the first attempt
    /// failed for a phone already sitting in the "power button down" landscape).
    @MainActor
    private func interfaceVideoOrientation() -> AVCaptureVideoOrientation {
        let io = self.bridge?.viewController?.view.window?.windowScene?.interfaceOrientation
        switch io {
        case .some(.portrait): return .portrait
        case .some(.portraitUpsideDown): return .portraitUpsideDown
        case .some(.landscapeLeft): return .landscapeLeft
        case .some(.landscapeRight): return .landscapeRight
        default: return self.lastVideoOrientation
        }
    }

    /// Apply the current interface orientation to the capture (both preview and
    /// stream come from the same mixer, so this fixes both). Called on setup AND
    /// on every setPreviewRect — the web re-reports the rect in a burst on
    /// `orientationchange`, so a rotation re-orients within that burst without a
    /// separate motion observer. Guarded so the mixer call fires only on a change.
    private func applyCurrentVideoOrientation() async {
        let vo = await MainActor.run { self.interfaceVideoOrientation() }
        guard !self.videoOrientationApplied || vo != self.lastVideoOrientation else { return }
        self.videoOrientationApplied = true
        self.lastVideoOrientation = vo
        await mixer.setVideoOrientation(vo)
    }

    // MARK: - Pipeline

    private func setupPipeline(width: Int, height: Int, fps: Double) async throws {
        // Screen-slide travel distance = the composite height (the screen image is
        // full-frame). Kept current in case the resolution changes.
        self.screenSlideHeight = CGFloat(height)
        // CAPTURE setup runs ONCE (or when the resolution changes). This is the ONLY
        // guard vs the club version — the real app's React effects churn
        // startPreview ~4x/sec, and a full capture re-attach on each call thrashes
        // the camera and starves the encoder (the 11fps / hung-preview bug).
        // Everything below (RTMP objects, single offscreen mode, stream-fed preview)
        // is club-exact and idempotent, so the churn becomes cheap no-ops.
        if !captureConfigured || configuredWidth != width || configuredHeight != height {
            _ = await AVCaptureDevice.requestAccess(for: .audio)

            // Capture at true native res (default preset is 720p → upscaled).
            let preset = sessionPreset(for: width, height: height)
            await mixer.setSessionPreset(preset)
            reportDiag("sessionPreset.set", ["preset": "\(preset.rawValue)", "w": width, "h": height])

            let camera = cameraDevice(for: currentLens) ?? AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back)
            self.currentDevice = camera
            do {
                try await mixer.attachVideo(camera, track: 0)
                reportDiag("attachVideo.ok", ["lens": currentLens, "device": camera?.localizedName ?? "nil"])
            } catch {
                reportDiag("attachVideo.error", ["error": error.localizedDescription])
            }
            if let mic = AVCaptureDevice.default(for: .audio) {
                do {
                    try await mixer.attachAudio(mic)
                    reportDiag("attachAudio.ok", ["device": mic.localizedName])
                } catch {
                    reportDiag("attachAudio.error", ["error": error.localizedDescription])
                }
            } else {
                reportDiag("attachAudio.noDevice", [:])
            }

            await setScreenSize(CGSize(width: width, height: height))

            captureConfigured = true
            configuredWidth = width
            configuredHeight = height
        }

        // Apply the frame rate whenever it CHANGES — NOT gated by captureConfigured.
        // The preview starts once (guarded) at whatever fps was selected then; if
        // the user later picks 1080p60, or go-live requests 60, the capture guard
        // above is skipped (same resolution) so the fps would otherwise never
        // update. setFrameRate re-selects a 60-capable activeFormat as needed.
        if fps != configuredFps {
            await mixer.setFrameRate(fps)
            configuredFps = fps
            reportDiag("frameRate.set", ["fps": fps])
        }

        // Create the RTMP objects if not already present (kept across preview→live;
        // recreated fresh after a stop).
        if connection == nil {
            let connection = RTMPConnection()
            let stream = RTMPStream(connection: connection)
            await mixer.addOutput(stream)
            self.connection = connection
            self.stream = stream
        }

        // .offscreen runs the screen compositor so camera + overlay reach the encoder
        // (in .passthrough the RTMPStream, videoTrackId == .max, gets no video).
        await mixer.setVideoMixerSettings(VideoMixerSettings(mode: .offscreen, mainTrack: 0))
        reportDiag("videoMixer.offscreen", ["mode": "offscreen", "mainTrack": 0])

        // Orient capture to the current interface orientation (outside the capture
        // guard so it re-applies as setupPipeline is re-invoked, e.g. after a
        // rotation). Guarded internally so the mixer call only fires on a change.
        await applyCurrentVideoOrientation()

        try await attachPreviewIfNeeded()
    }

    private func attachPreviewIfNeeded() async throws {
        if previewView == nil {
            await MainActor.run {
                guard let container = self.bridge?.viewController?.view else { return }
                // Rounded clipping wrapper (the MTHKView's own cornerRadius won't
                // clip its Metal drawable). The MTHKView fills the wrapper.
                let wrap = UIView(frame: .zero)
                wrap.layer.cornerRadius = 16
                wrap.layer.masksToBounds = true
                wrap.clipsToBounds = true
                wrap.backgroundColor = .clear
                wrap.isHidden = true
                wrap.isUserInteractionEnabled = true

                // resizeAspect (NOT resizeAspectFill): show the FULL composited
                // 16:9 frame so the scoreboard (bottom of the frame) stays visible.
                let view = MTHKView(frame: wrap.bounds)
                view.videoGravity = .resizeAspect
                view.autoresizingMask = [.flexibleWidth, .flexibleHeight]

                // Pinch-to-zoom directly on the preview (the web zoom control
                // can't float over this native layer). On the wrapper so it works
                // across the whole preview area.
                let pinch = UIPinchGestureRecognizer(target: self, action: #selector(self.handlePinch(_:)))
                wrap.addGestureRecognizer(pinch)

                wrap.addSubview(view)
                container.addSubview(wrap)
                self.previewContainer = wrap
                self.previewView = view
            }
        }
        // Feed the preview from the MIXER's offscreen composite (camera + overlay),
        // NOT the RTMPStream. The stream (a separate mixer output) is untouched, so
        // streaming is unaffected — but the view now gets the composite CONTINUOUSLY,
        // independent of publishing. So the scoreboard shows on the preview before
        // going live, survives Stop, and updates live when the board changes (a
        // stream-fed preview only rendered while actively publishing). MTHKView's
        // videoTrackId defaults to UInt8.max — the offscreen composite track — and
        // mixer.addOutput is idempotent, so calling it each setup is safe.
        if let view = self.previewView {
            await mixer.addOutput(view)
        }
        await self.applyPreviewRect()
    }

    /// Position the camera preview onto the web-provided box rect, on top of the
    /// WebView. Rect is in web-viewport points; convert to the container's
    /// coordinate space by adding the WebView origin + its content inset (status
    /// bar / safe area). A zero-size rect hides the preview.
    @MainActor
    private func applyPreviewRect() {
        guard let wrap = self.previewContainer else { return }
        guard let rect = self.previewRect, rect.width > 1, rect.height > 1 else {
            wrap.isHidden = true
            return
        }
        guard let container = self.bridge?.viewController?.view else { return }
        var offsetX: CGFloat = 0
        var offsetY: CGFloat = 0
        if let webView = self.bridge?.webView {
            let inset = webView.scrollView.adjustedContentInset
            let originInContainer = webView.convert(CGPoint(x: inset.left, y: inset.top), to: container)
            offsetX = originInContainer.x
            offsetY = originInContainer.y
        }
        wrap.frame = CGRect(
            x: offsetX + rect.origin.x,
            y: offsetY + rect.origin.y,
            width: rect.width,
            height: rect.height
        )
        container.bringSubviewToFront(wrap)
        wrap.isHidden = false
    }

    private var pinchBaseZoom: CGFloat = 1.0

    @objc private func handlePinch(_ gesture: UIPinchGestureRecognizer) {
        guard let device = self.currentDevice else { return }
        switch gesture.state {
        case .began:
            pinchBaseZoom = device.videoZoomFactor
        case .changed:
            let maxZoom = min(device.maxAvailableVideoZoomFactor, 10.0)
            let newZoom = max(1.0, min(pinchBaseZoom * gesture.scale, maxZoom))
            do {
                try device.lockForConfiguration()
                device.videoZoomFactor = newZoom
                device.unlockForConfiguration()
                self.emit(["state": "zoom", "factor": Double(newZoom)])
            } catch {
                self.reportDiag("pinch.error", ["error": error.localizedDescription])
            }
        default:
            break
        }
    }

    /// Open an OAuth flow in the system browser (Safari) via
    /// ASWebAuthenticationSession — this uses a real Safari user-agent, so
    /// Google does NOT block it with disallowed_useragent (unlike the WKWebView).
    /// The server callback redirects to `callbackScheme://…?tempToken=…`, which
    /// this session captures and returns to JS. JS then exchanges the temp token
    /// for a real session cookie in the WebView. Reuses the existing verified
    /// OAuth client — Google still redirects to the same https callback and never
    /// sees the custom scheme, so no re-verification is needed.
    @objc func startOAuth(_ call: CAPPluginCall) {
        guard let urlString = call.getString("url"),
              let authURL = URL(string: urlString),
              let scheme = call.getString("callbackScheme") else {
            call.reject("url and callbackScheme are required")
            return
        }
        DispatchQueue.main.async {
            let session = ASWebAuthenticationSession(url: authURL, callbackURLScheme: scheme) { callbackURL, error in
                if let error = error {
                    call.reject("OAuth failed or cancelled: \(error.localizedDescription)")
                    return
                }
                guard let callbackURL = callbackURL else {
                    call.reject("No callback URL returned from OAuth")
                    return
                }
                call.resolve(["url": callbackURL.absoluteString])
            }
            session.presentationContextProvider = self
            session.prefersEphemeralWebBrowserSession = false
            self.authSession = session
            session.start()
        }
    }

    @objc func setPreviewRect(_ call: CAPPluginCall) {
        let x = CGFloat(call.getDouble("x") ?? 0)
        let y = CGFloat(call.getDouble("y") ?? 0)
        let w = CGFloat(call.getDouble("width") ?? 0)
        let h = CGFloat(call.getDouble("height") ?? 0)
        self.previewRect = CGRect(x: x, y: y, width: w, height: h)
        Task {
            await MainActor.run { self.applyPreviewRect() }
            // Re-orient on rotation: the web fires a burst of setPreviewRect calls
            // on orientationchange, so re-check the interface orientation here.
            await self.applyCurrentVideoOrientation()
            call.resolve()
        }
    }

    @ScreenActor
    private func setScreenSize(_ size: CGSize) {
        mixer.screen.size = size
        ensureOverlayLayers()
        // The screen layer needs an EXPLICIT full-frame size. With size == .zero a
        // ScreenObject auto-sizes to (parent − layoutMargin), so a negative top
        // margin would inflate its height instead of translating it — breaking the
        // slide. A fixed size makes layoutMargin.top a pure vertical translate.
        // (board/top keep size == .zero so they fill the frame at margin 0.)
        screenLayer?.size = size
    }

    private func sessionPreset(for width: Int, height: Int) -> AVCaptureSession.Preset {
        switch (width, height) {
        case (3840, 2160): return .hd4K3840x2160
        case (1920, 1080): return .hd1920x1080
        case (1280, 720): return .hd1280x720
        default: return .high
        }
    }

    private func thermalStateString() -> String {
        switch ProcessInfo.processInfo.thermalState {
        case .nominal: return "nominal"
        case .fair: return "fair"
        case .serious: return "serious"
        case .critical: return "critical"
        @unknown default: return "unknown"
        }
    }

    /// Thermal-adaptive target. Only throttles at CRITICAL (genuine thermal risk /
    /// imminent shutdown). "serious" is common under sustained 1080p60 and the phone
    /// handles it fine, so we keep full bitrate there — the user wants their full
    /// 12 Mbps. Restores automatically once it drops back below critical.
    private func bitrateForThermal() -> Int {
        switch ProcessInfo.processInfo.thermalState {
        case .critical: return Int(Double(targetBitrate) * 0.65)
        default: return targetBitrate   // nominal / fair / serious → full quality
        }
    }

    private func cameraDevice(for lens: String) -> AVCaptureDevice? {
        switch lens {
        case "ultrawide":
            return AVCaptureDevice.default(.builtInUltraWideCamera, for: .video, position: .back)
        case "tele":
            return AVCaptureDevice.default(.builtInTelephotoCamera, for: .video, position: .back)
        case "front":
            return AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .front)
        default:
            return AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back)
        }
    }

    // MARK: - Reconnect

    /// Fired when the RTMP connection drops unexpectedly (not a user Stop). PROVEN
    /// club reconnect: recreate the RTMP objects and re-publish the same key.
    private func handleUnexpectedClose() async {
        guard !userStopped, !reconnecting else { return }
        reconnecting = true
        reportDiag("reconnect.begin", [:])
        var attempt = 0
        while !userStopped && attempt < 30 {
            attempt += 1
            try? await Task.sleep(nanoseconds: 3_000_000_000) // 3s backoff
            if userStopped { break }
            do {
                await rebuildStreamObjects()
                try await goLive()
                reportDiag("reconnect.ok", ["attempt": attempt])
                emit(["state": "live", "reconnected": true])
                break
            } catch {
                reportDiag("reconnect.retry", ["attempt": attempt, "error": error.localizedDescription])
            }
        }
        reconnecting = false
    }

    /// Recreate just the RTMP connection/stream (keep camera/mixer/preview/overlay).
    private func rebuildStreamObjects() async {
        if let stream = self.stream {
            _ = try? await stream.close()
            await mixer.removeOutput(stream)
        }
        if let connection = self.connection {
            _ = try? await connection.close()
        }
        let c = RTMPConnection()
        let s = RTMPStream(connection: c)
        await mixer.addOutput(s)
        self.connection = c
        self.stream = s
        self.observersStarted = false
        // Preview is a MIXER output now — it keeps running across this stream
        // rebuild untouched, so there's nothing to re-attach here.
    }

    // MARK: - Observers / diagnostics

    private func startObservers() {
        guard !observersStarted, let connection = self.connection, let stream = self.stream else { return }
        observersStarted = true

        Task { [weak self] in
            let statusStream = await connection.status
            for await s in statusStream {
                self?.reportDiag("rtmp.connection.status", ["code": "\(s.code)", "level": "\(s.level)"])
                if "\(s.code)" == "NetConnection.Connect.Closed" {
                    Task { await self?.handleUnexpectedClose() }
                }
            }
        }
        Task { [weak self] in
            let statusStream = await stream.status
            for await s in statusStream {
                self?.reportDiag("rtmp.stream.status", ["code": "\(s.code)", "level": "\(s.level)"])
            }
        }
        // Media-flow tick: runs until the connection drops. Also applies
        // thermal-adaptive bitrate (throttle when hot, restore when cool).
        let tickStream = stream
        let tickStart = Date()
        Task { [weak self] in
            while true {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                guard let self, let stream = self.stream, let connection = self.connection else { break }
                // Stop if a reconnect swapped in a new stream (avoid duplicate ticks).
                guard stream === tickStream else { break }
                let connected = await connection.connected
                let fps = await stream.currentFPS
                let ready = await stream.readyState
                let info = await stream.info

                let desired = self.bitrateForThermal()
                if desired != self.appliedBitrate {
                    var vs = await stream.videoSettings
                    vs.bitRate = desired
                    await stream.setVideoSettings(vs)   // live, no encoder rebuild
                    self.appliedBitrate = desired
                    self.reportDiag("bitrate.adapt", ["bitRate": desired, "thermal": self.thermalStateString()])
                }

                // Capture-side target fps (from the device's min frame duration) — if
                // this stays 60 but stream fps drops, the ENCODER/compositor is the
                // bottleneck; if it drops too, the CAPTURE was throttled. memMB rules
                // out a leak; elapsedSec lets us plot the drop over time.
                var camTargetFps = 0
                if let dur = self.currentDevice?.activeVideoMinFrameDuration, dur.seconds > 0 {
                    camTargetFps = Int((1.0 / dur.seconds).rounded())
                }
                self.reportDiag("media.tick", [
                    "fps": Int(fps),
                    "elapsedSec": Int(Date().timeIntervalSince(tickStart)),
                    "camTargetFps": camTargetFps,
                    "memMB": self.residentMemoryMB(),
                    "readyState": "\(ready)",
                    "connected": connected,
                    "byteCount": info.byteCount,
                    "bytesPerSec": info.currentBytesPerSecond,
                    "thermal": self.thermalStateString(),
                    "bitRate": self.appliedBitrate
                ])
                if !connected { break }
            }
        }
    }

    /// Physical memory footprint (MB) — the figure iOS uses for jetsam. Growing
    /// steadily over a stream would indicate a leak (e.g. overlay CGImages not
    /// released) rather than thermal throttling.
    private func residentMemoryMB() -> Int {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size) / 4
        let kr = withUnsafeMutablePointer(to: &info) { ptr in
            ptr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        guard kr == KERN_SUCCESS else { return -1 }
        return Int(info.phys_footprint / (1024 * 1024))
    }

    // Master switch for the network diagnostics. Currently ON to investigate the
    // 1080p60 fps drop after ~2-3 min. The heavy per-overlay-frame POST is gone
    // (the layered path doesn't diag per push), so what POSTs now is low-volume:
    // mostly one-time setup events + media.tick every 2s (fps/thermal/mem/elapsed).
    // Set back to false once the fps drop is diagnosed + fixed.
    private static let debugDiagnosticsEnabled = true

    private func reportDiag(_ event: String, _ extra: [String: Any]) {
        var dict: [String: Any] = [
            "kind": "native-stream-diag",
            "event": event,
            "t": ISO8601DateFormatter().string(from: Date())
        ]
        for (k, v) in extra { dict[k] = v }
        // Keep emitting to JS (media.tick → bitrate indicator); only the network
        // POST is gated off.
        emit(dict)
        guard Self.debugDiagnosticsEnabled else { return }
        guard let url = URL(string: "https://app.147pro.com/_api/stream-diag"),
              let body = try? JSONSerialization.data(withJSONObject: dict) else { return }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("text/plain", forHTTPHeaderField: "Content-Type")
        req.httpBody = body
        URLSession.shared.dataTask(with: req).resume()
    }

    private func emit(_ data: [String: Any]) {
        notifyListeners("status", data: data)
    }
}

extension StreamerPlugin: ASWebAuthenticationPresentationContextProviding {
    public func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        return self.bridge?.viewController?.view.window ?? ASPresentationAnchor()
    }
}
