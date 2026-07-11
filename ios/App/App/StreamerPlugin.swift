import Foundation
import Capacitor
import HaishinKit
import AVFoundation
import UIKit

/// Native streaming plugin for the 147 Pro PoC.
///
/// Proves the core hypothesis: capture the camera at **true 1080p60** via
/// AVFoundation (which the WebKit `getUserMedia` sandbox can't expose), composite
/// a scoreboard overlay, hardware-encode H.264, and push **RTMP directly to
/// YouTube** — no MediaMTX, no WebRTC ceilings.
///
/// Built against HaishinKit 2.x (async `MediaMixer` API). NOTE: this is written
/// on Windows without a compiler — expect 1–2 cloud-build passes to settle exact
/// API signatures against the pinned HaishinKit version.
@objc(StreamerPlugin)
public class StreamerPlugin: CAPPlugin, CAPBridgedPlugin {
    public let identifier = "StreamerPlugin"
    public let jsName = "Streamer"
    public let pluginMethods: [CAPPluginMethod] = [
        CAPPluginMethod(name: "startPreview", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "startStream", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "stopStream", returnType: CAPPluginReturnPromise)
    ]

    private let mixer = MediaMixer(captureSessionMode: .single)
    private var connection: RTMPConnection?
    private var stream: RTMPStream?
    private var previewView: MTHKView?
    private var overlay: ImageScreenObject?
    private var configuredSize = CGSize(width: 1920, height: 1080)

    // MARK: - JS API

    @objc func startPreview(_ call: CAPPluginCall) {
        let width = call.getInt("width") ?? 1920
        let height = call.getInt("height") ?? 1080
        let fps = Double(call.getInt("fps") ?? 60)
        Task {
            do {
                try await self.setupPreview(width: width, height: height, fps: fps)
                self.emit(["state": "preview", "width": width, "height": height, "fps": fps])
                call.resolve()
            } catch {
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
                // Ensure the capture pipeline + preview exist.
                try await self.setupPreview(width: width, height: height, fps: fps)

                let connection = RTMPConnection()
                let stream = RTMPStream(connection: connection)

                // Encoder settings: true 1080p60 at the requested bitrate. Because
                // this is a native encode (not WebRTC) we can set the bitrate
                // directly — no GCC ramp — and use High profile with B-frames.
                var videoSettings = await stream.videoSettings
                videoSettings.videoSize = CGSize(width: width, height: height)
                videoSettings.bitRate = bitrate
                videoSettings.expectedFrameRate = fps
                videoSettings.profileLevel = kVTProfileLevel_H264_High_AutoLevel as String
                try await stream.setVideoSettings(videoSettings)

                await mixer.addOutput(stream)

                self.connection = connection
                self.stream = stream

                // YouTube: connect to the app URL (…/live2), publish with the key.
                _ = try await connection.connect(url)
                _ = try await stream.publish(streamKey)

                self.emit(["state": "live", "width": width, "height": height, "fps": fps, "bitrate": bitrate])
                call.resolve()
            } catch {
                call.reject("startStream failed: \(error.localizedDescription)")
            }
        }
    }

    @objc func stopStream(_ call: CAPPluginCall) {
        Task {
            do {
                if let stream = self.stream {
                    _ = try? await stream.close()
                    await mixer.removeOutput(stream)
                }
                if let connection = self.connection {
                    _ = try? await connection.close()
                }
                self.stream = nil
                self.connection = nil
                self.emit(["state": "idle"])
                call.resolve()
            }
        }
    }

    // MARK: - Pipeline setup

    private func setupPreview(width: Int, height: Int, fps: Double) async throws {
        configuredSize = CGSize(width: width, height: height)

        // Camera + mic.
        let camera = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back)
        try await mixer.attachVideo(camera, track: 0) { unit in
            unit.isVideoMirrored = false
        }
        try? await mixer.attachAudio(AVCaptureDevice.default(for: .audio))

        // Output/composition size + frame rate. setFrameRate drives the capture
        // device toward a 60fps-capable format (the whole point of going native).
        await mixer.setVideoOrientation(.landscapeRight)
        await MainActor.run { self.mixer.screen.size = self.configuredSize }
        try await mixer.setFrameRate(fps)

        try await addOverlayIfNeeded()
        try await attachPreviewIfNeeded()
    }

    /// Static scoreboard-style overlay to prove 1:1 overlay compositing at 1080p.
    /// In the real app this bitmap comes from the existing web overlay renderer
    /// via `updateOverlay(bitmap)`; here we draw a placeholder natively.
    private func addOverlayIfNeeded() async throws {
        guard overlay == nil else { return }
        let obj = ImageScreenObject()
        if let cg = Self.makeScoreboardImage(width: 640, height: 96) {
            obj.cgImage = cg
        }
        obj.size = CGSize(width: 640, height: 96)
        obj.horizontalAlignment = .center
        obj.verticalAlignment = .bottom
        obj.layoutMargin = .init(top: 0, left: 0, bottom: 48, right: 0)
        try? await mixer.screen.addChild(obj)
        overlay = obj
    }

    private func attachPreviewIfNeeded() async throws {
        await MainActor.run {
            guard self.previewView == nil, let container = self.bridge?.viewController?.view else { return }
            let view = MTHKView(frame: container.bounds)
            view.videoGravity = .resizeAspectFill
            view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            // Behind the (transparent) Capacitor WebView so web UI floats on top.
            container.insertSubview(view, at: 0)
            self.previewView = view
            if let webView = self.webView {
                webView.isOpaque = false
                webView.backgroundColor = .clear
                webView.scrollView.backgroundColor = .clear
            }
        }
        if let view = previewView {
            await mixer.addOutput(view)
        }
    }

    private func emit(_ data: [String: Any]) {
        notifyListeners("status", data: data)
    }

    private static func makeScoreboardImage(width: Int, height: Int) -> CGImage? {
        let size = CGSize(width: width, height: height)
        let renderer = UIGraphicsImageRenderer(size: size)
        let image = renderer.image { ctx in
            let rect = CGRect(origin: .zero, size: size)
            let path = UIBezierPath(roundedRect: rect, cornerRadius: 16)
            UIColor(white: 0, alpha: 0.55).setFill()
            path.fill()
            let title = "147 PRO  •  1080p60 NATIVE TEST"
            let attrs: [NSAttributedString.Key: Any] = [
                .foregroundColor: UIColor.white,
                .font: UIFont.systemFont(ofSize: 30, weight: .bold)
            ]
            let ts = title.size(withAttributes: attrs)
            title.draw(at: CGPoint(x: (size.width - ts.width) / 2, y: (size.height - ts.height) / 2), withAttributes: attrs)
        }
        return image.cgImage
    }
}
