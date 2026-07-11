import Foundation
import Capacitor
import HaishinKit
import AVFoundation
import VideoToolbox
import UIKit

/// Native streaming plugin for the 147 Pro PoC.
///
/// Proves the core hypothesis: capture the camera at **true 1080p60** via
/// AVFoundation (which the WebKit `getUserMedia` sandbox can't expose), hardware
/// H.264 encode, and push **RTMP directly to YouTube** — no MediaMTX, no WebRTC
/// ceilings.
///
/// Written against **HaishinKit 2.0.9** (the latest on CocoaPods trunk; 2.1/2.2
/// are SPM-only). API verified from HaishinKit's own 2.0.9 sources.
///
/// This build is DIAGNOSTIC-HEAVY: every stage of go-live (attach, connect,
/// publish) plus a live media-flow tick (fps / bytes / readyState) and both RTMP
/// status streams are shipped to the droplet (`/_api/stream-diag`) AND emitted to
/// the JS `status` listener, so we can see exactly why YouTube shows "no data"
/// even though publish resolves.
@objc(StreamerPlugin)
public class StreamerPlugin: CAPPlugin, CAPBridgedPlugin {
    public let identifier = "StreamerPlugin"
    public let jsName = "Streamer"
    public let pluginMethods: [CAPPluginMethod] = [
        CAPPluginMethod(name: "startPreview", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "startStream", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "stopStream", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "setLens", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "setOverlay", returnType: CAPPluginReturnPromise)
    ]

    // Scoreboard overlay, composited on the HaishinKit screen (so it appears in
    // both the native preview and the encoded stream). @ScreenActor-isolated.
    @ScreenActor private var scoreboard: TextScreenObject?

    // Single back camera, auto-managed capture session.
    private let mixer = MediaMixer(
        multiCamSessionEnabled: false,
        multiTrackAudioMixingEnabled: false,
        useManualCapture: false
    )
    private var connection: RTMPConnection?
    private var stream: RTMPStream?
    private var previewView: MTHKView?
    private var isPreviewing = false
    private var currentLens = "wide"
    private var observersStarted = false

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
        let bitrate = call.getInt("bitrate") ?? 9_000_000
        Task {
            do {
                try await self.setupPipeline(width: width, height: height, fps: fps)
                guard let connection = self.connection, let stream = self.stream else {
                    call.reject("pipeline not ready")
                    return
                }

                // Report camera/mic authorization — a denied mic is a common cause
                // of YouTube showing "no data" (it wants an audio track).
                self.reportDiag("perms", [
                    "camera": "\(AVCaptureDevice.authorizationStatus(for: .video).rawValue)",
                    "mic": "\(AVCaptureDevice.authorizationStatus(for: .audio).rawValue)"
                ])

                // Encoder settings — native encode, so we set the bitrate directly
                // (no WebRTC GCC ramp) at true 1080p60.
                var videoSettings = await stream.videoSettings
                videoSettings.videoSize = CGSize(width: width, height: height)
                videoSettings.bitRate = bitrate
                // THE fps-0 FIX. VideoCodecSettings defaults profileLevel to
                // kVTProfileLevel_H264_Baseline_3_1 — but H.264 Level 3.1 tops out at
                // 1280x720. Feeding a 1920x1080 frame to a Baseline-3.1 VTCompression
                // session makes VideoToolbox produce ZERO output (currentFPS 0) while
                // audio still flows, so YouTube saw no video and dropped us. High +
                // AutoLevel lets VideoToolbox pick Level 4.2 (needed for 1080p60) and
                // is also the High profile we want for quality.
                videoSettings.profileLevel = kVTProfileLevel_H264_High_AutoLevel as String
                await stream.setVideoSettings(videoSettings)
                self.reportDiag("videoSettings.applied", ["w": width, "h": height, "bitRate": bitrate, "profile": "H264_High_AutoLevel"])

                // Begin draining status + media-flow BEFORE connect so we capture
                // the RTMP handshake codes.
                self.startObservers()

                // YouTube: connect to the app URL (…/live2), publish with the key.
                self.reportDiag("connect.attempt", ["url": url])
                _ = try await connection.connect(url)
                self.reportDiag("connect.ok", ["connected": await connection.connected])

                self.reportDiag("publish.attempt", ["keyPrefix": String(streamKey.prefix(4)) + "…"])
                _ = try await stream.publish(streamKey)
                self.reportDiag("publish.ok", ["readyState": "\(await stream.readyState)"])

                self.emit(["state": "live", "width": width, "height": height, "fps": Int(fps), "bitrate": bitrate])
                call.resolve()
            } catch {
                self.reportDiag("startStream.error", ["error": error.localizedDescription, "errorFull": "\(error)"])
                call.reject("startStream failed: \(error.localizedDescription)")
            }
        }
    }

    @objc func stopStream(_ call: CAPPluginCall) {
        Task {
            if let stream = self.stream {
                _ = try? await stream.close()
            }
            if let connection = self.connection {
                _ = try? await connection.close()
            }
            self.emit(["state": "idle"])
            call.resolve()
        }
    }

    /// Update the scoreboard overlay text. Proves web-driven overlays composite
    /// into the native 1080p60 stream — the core feature. In the real app this
    /// text is replaced by an ImageScreenObject fed the web scoreboard bitmap.
    @objc func setOverlay(_ call: CAPPluginCall) {
        let text = call.getString("text") ?? ""
        Task {
            await self.updateScoreboard(text)
            self.reportDiag("overlay.set", ["text": text])
            call.resolve()
        }
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

    /// Live camera-lens switch. iPhone back lenses: "wide" (1x), "ultrawide"
    /// (0.5x), "tele" (3x); plus "front". Needed because the user's wide lens is
    /// physically damaged.
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
                self.reportDiag("lens.set", ["lens": lens, "device": device.localizedName])
                self.emit(["state": "lens", "lens": lens])
                call.resolve(["lens": lens])
            } catch {
                self.reportDiag("lens.error", ["lens": lens, "error": error.localizedDescription])
                call.reject("lens switch failed: \(error.localizedDescription)")
            }
        }
    }

    // MARK: - Pipeline

    private func setupPipeline(width: Int, height: Int, fps: Double) async throws {
        // Proactively request mic access so audio actually attaches (YouTube wants
        // an audio track); camera is prompted by attachVideo.
        _ = await AVCaptureDevice.requestAccess(for: .audio)

        // Camera + mic.
        let camera = cameraDevice(for: currentLens) ?? AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back)
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

        // Landscape capture. This is THE fix for fps 0: the phone captures portrait
        // by default, so a portrait buffer (e.g. 1080x1920) was hitting an encoder
        // configured for 1920x1080 landscape — a size mismatch the H.264 encoder
        // silently rejects, so ZERO video frames were produced while audio flowed.
        // Forcing landscape makes the capture buffers 1920x1080, matching the
        // encoder + screen size. It also fixes the "stays portrait in landscape"
        // preview. (A snooker/pool stream is landscape anyway.)
        await mixer.setVideoOrientation(.landscapeRight)
        reportDiag("videoOrientation.set", ["orientation": "landscapeRight"])

        // Output/composition size + capture frame rate. setFrameRate drives the
        // device toward a 60fps-capable format — the whole point of going native.
        await mixer.setFrameRate(fps)
        // screen.size is @ScreenActor-isolated, so mutate it on that actor.
        await setScreenSize(CGSize(width: width, height: height))

        // Create the RTMP stream up front so the preview can render through it,
        // even before we connect/publish.
        if connection == nil {
            let connection = RTMPConnection()
            let stream = RTMPStream(connection: connection)
            await mixer.addOutput(stream)       // capture → encoder/stream
            self.connection = connection
            self.stream = stream
        }

        // THE fps-0 FIX. MediaMixer defaults to VideoMixerSettings.mode == .passthrough.
        // In passthrough the offscreen screen-compositor loop is stopped, and raw
        // camera frames are only delivered to outputs whose videoTrackId == the
        // capture track (0). But RTMPStream.videoTrackId defaults to UInt8.max, so it
        // was NEVER receiving video — currentFPS 0 while audio (which has no such
        // gate) flowed. Switching to .offscreen starts the screen display-link
        // compositor, which renders the camera (track 0) into the 1920x1080 screen
        // canvas and delivers it to UInt8.max outputs (our RTMPStream) → real video.
        // This is also the mode the scoreboard overlay will need (mixer.screen).
        await mixer.setVideoMixerSettings(VideoMixerSettings(mode: .offscreen, mainTrack: 0))
        reportDiag("videoMixer.offscreen", ["mode": "offscreen", "mainTrack": 0])

        try await attachPreviewIfNeeded()
        await updateScoreboard("0 - 0")
        isPreviewing = true
    }

    private func attachPreviewIfNeeded() async throws {
        if previewView == nil {
            await MainActor.run {
                guard let container = self.bridge?.viewController?.view else { return }
                let view = MTHKView(frame: container.bounds)
                // .resizeAspect = show the true 16:9 landscape frame (WYSIWYG of
                // what's streamed), rather than cropping to fill.
                view.videoGravity = .resizeAspect
                view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
                // Behind the (transparent) Capacitor WebView so web UI floats on top.
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
            await stream.addOutput(view)         // stream → preview
        }
    }

    // Mutations of the HaishinKit compositor screen must happen on @ScreenActor.
    @ScreenActor
    private func setScreenSize(_ size: CGSize) {
        mixer.screen.size = size
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

    // MARK: - Diagnostics

    /// Drain both RTMP status streams and poll media-flow so we can see whether
    /// bytes/frames are actually leaving the device after publish resolves.
    private func startObservers() {
        guard !observersStarted, let connection = self.connection, let stream = self.stream else { return }
        observersStarted = true

        Task { [weak self] in
            let statusStream = await connection.status
            for await s in statusStream {
                self?.reportDiag("rtmp.connection.status", ["code": "\(s.code)", "level": "\(s.level)"])
            }
        }
        Task { [weak self] in
            let statusStream = await stream.status
            for await s in statusStream {
                self?.reportDiag("rtmp.stream.status", ["code": "\(s.code)", "level": "\(s.level)"])
            }
        }
        // Media-flow ticks: fps>0 and bytesPerSec>0 => media IS reaching YouTube.
        Task { [weak self] in
            for _ in 0..<30 {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                guard let self, let stream = self.stream, let connection = self.connection else { break }
                let fps = await stream.currentFPS
                let ready = await stream.readyState
                let connected = await connection.connected
                let info = await stream.info
                self.reportDiag("media.tick", [
                    "fps": Int(fps),
                    "readyState": "\(ready)",
                    "connected": connected,
                    "byteCount": info.byteCount,
                    "bytesPerSec": info.currentBytesPerSecond
                ])
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
