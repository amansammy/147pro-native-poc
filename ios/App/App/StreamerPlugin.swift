import Foundation
import Capacitor
import HaishinKit
import AVFoundation
import VideoToolbox
import UIKit

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
        CAPPluginMethod(name: "setZoom", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "setFocusExposureLock", returnType: CAPPluginReturnPromise)
    ]

    // Scoreboard overlays composited on the HaishinKit screen (appear in both the
    // native preview and the encoded stream). @ScreenActor-isolated.
    // - scoreboard: legacy plain-text placeholder.
    // - overlayImage: the REAL path — a full-frame transparent PNG rendered by the
    //   web control page (a broadcast Pro-TV scoreboard), composited 1:1.
    @ScreenActor private var scoreboard: TextScreenObject?
    @ScreenActor private var overlayImage: ImageScreenObject?

    private let mixer = MediaMixer(
        multiCamSessionEnabled: false,
        multiTrackAudioMixingEnabled: false,
        useManualCapture: false
    )
    private var connection: RTMPConnection?
    private var stream: RTMPStream?
    private var previewView: MTHKView?
    private var currentLens = "wide"
    private var currentDevice: AVCaptureDevice?
    private var observersStarted = false

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
        Task {
            do {
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
            self.userStopped = true
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

    /// Composite a full-frame transparent overlay bitmap (the real broadcast
    /// scoreboard rendered by the web control page) onto the stream. This is the
    /// production bitmap-bridge: web draws pixels → native composites them, so ALL
    /// overlays (any Pro-TV board, pool board, sponsors, watermark) reuse one path.
    @objc func updateOverlay(_ call: CAPPluginCall) {
        let img = call.getString("image") ?? ""
        Task {
            let ok = await self.applyOverlayImage(img)
            self.reportDiag("overlay.image", ["ok": ok, "bytes": img.count])
            call.resolve(["ok": ok])
        }
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

    // MARK: - Pipeline

    private func setupPipeline(width: Int, height: Int, fps: Double) async throws {
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

        // Landscape capture (matches the 16:9 encoder + a snooker/pool stream).
        await mixer.setVideoOrientation(.landscapeRight)
        await mixer.setFrameRate(fps)
        await setScreenSize(CGSize(width: width, height: height))

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

        try await attachPreviewIfNeeded()
        // No placeholder text — the real broadcast board arrives via updateOverlay
        // (rendered by the web control page) on the first poll.
    }

    private func attachPreviewIfNeeded() async throws {
        if previewView == nil {
            await MainActor.run {
                guard let container = self.bridge?.viewController?.view else { return }
                let view = MTHKView(frame: container.bounds)
                view.videoGravity = .resizeAspect
                view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
                container.insertSubview(view, at: 0)
                self.previewView = view
                if let webView = self.bridge?.webView {
                    webView.isOpaque = false
                    webView.backgroundColor = .clear
                    webView.scrollView.backgroundColor = .clear
                }
            }
        }
        if let view = previewView, let stream = self.stream {
            await stream.addOutput(view)
        }
    }

    @ScreenActor
    private func setScreenSize(_ size: CGSize) {
        mixer.screen.size = size
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

    /// Thermal-adaptive target: throttle when hot, RESTORE to full when it cools.
    private func bitrateForThermal() -> Int {
        switch ProcessInfo.processInfo.thermalState {
        case .serious: return Int(Double(targetBitrate) * 0.6)
        case .critical: return Int(Double(targetBitrate) * 0.4)
        default: return targetBitrate   // nominal / fair → full quality
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

    /// Fired when the RTMP connection drops unexpectedly (not a user Stop).
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
        if let view = self.previewView {
            await s.addOutput(view)
        }
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

                self.reportDiag("media.tick", [
                    "fps": Int(fps),
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

    private func reportDiag(_ event: String, _ extra: [String: Any]) {
        var dict: [String: Any] = [
            "kind": "native-stream-diag",
            "event": event,
            "t": ISO8601DateFormatter().string(from: Date())
        ]
        for (k, v) in extra { dict[k] = v }
        emit(dict)
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
