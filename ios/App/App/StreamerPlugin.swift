import Foundation
import Capacitor
import HaishinKit
import AVFoundation
import UIKit

/// Native streaming plugin for the 147 Pro PoC.
///
/// Proves the core hypothesis: capture the camera at **true 1080p60** via
/// AVFoundation (which the WebKit `getUserMedia` sandbox can't expose), hardware
/// H.264 encode, and push **RTMP directly to YouTube** — no MediaMTX, no WebRTC
/// ceilings.
///
/// Written against **HaishinKit 2.0.9** (the latest on CocoaPods trunk; 2.1/2.2
/// are SPM-only). API verified from HaishinKit's own 2.0.9 IngestViewController
/// example. v1 intentionally has NO overlay — first we prove 1080p60 lands on
/// YouTube; the scoreboard overlay (ImageScreenObject / mixer.screen) is the next
/// milestone once capture+encode+RTMP is green.
@objc(StreamerPlugin)
public class StreamerPlugin: CAPPlugin, CAPBridgedPlugin {
    public let identifier = "StreamerPlugin"
    public let jsName = "Streamer"
    public let pluginMethods: [CAPPluginMethod] = [
        CAPPluginMethod(name: "startPreview", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "startStream", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "stopStream", returnType: CAPPluginReturnPromise)
    ]

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

    // MARK: - JS API

    @objc func startPreview(_ call: CAPPluginCall) {
        let width = call.getInt("width") ?? 1920
        let height = call.getInt("height") ?? 1080
        let fps = Double(call.getInt("fps") ?? 60)
        Task {
            do {
                try await self.setupPipeline(width: width, height: height, fps: fps)
                self.emit(["state": "preview", "width": width, "height": height, "fps": Int(fps)])
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
                try await self.setupPipeline(width: width, height: height, fps: fps)
                guard let connection = self.connection, let stream = self.stream else {
                    call.reject("pipeline not ready")
                    return
                }

                // Encoder settings — native encode, so we set the bitrate directly
                // (no WebRTC GCC ramp) at true 1080p60.
                var videoSettings = await stream.videoSettings
                videoSettings.videoSize = CGSize(width: width, height: height)
                videoSettings.bitRate = bitrate
                await stream.setVideoSettings(videoSettings)

                // YouTube: connect to the app URL (…/live2), publish with the key.
                _ = try await connection.connect(url)
                _ = try await stream.publish(streamKey)

                self.emit(["state": "live", "width": width, "height": height, "fps": Int(fps), "bitrate": bitrate])
                call.resolve()
            } catch {
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

    // MARK: - Pipeline

    private func setupPipeline(width: Int, height: Int, fps: Double) async throws {
        // Camera + mic.
        let camera = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back)
        try? await mixer.attachVideo(camera, track: 0)
        try? await mixer.attachAudio(AVCaptureDevice.default(for: .audio))

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

        try await attachPreviewIfNeeded()
        isPreviewing = true
    }

    private func attachPreviewIfNeeded() async throws {
        if previewView == nil {
            await MainActor.run {
                guard let container = self.bridge?.viewController?.view else { return }
                let view = MTHKView(frame: container.bounds)
                view.videoGravity = .resizeAspectFill
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

    private func emit(_ data: [String: Any]) {
        notifyListeners("status", data: data)
    }
}
