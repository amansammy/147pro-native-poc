import UIKit
import Capacitor

/// Capacitor's iOS bridge stopped auto-discovering app-local plugins via the
/// Objective-C runtime scan in Capacitor 6/7. A plugin defined directly in this
/// app target (i.e. not shipped as a pod/SPM package) is therefore NOT registered
/// unless we register its instance explicitly here.
///
/// Device diagnostics (2026-07-11) proved the symptom: `window.Capacitor` was
/// injected (platform ios, isNative true) but `Capacitor.Plugins` held only the
/// four built-ins (CapacitorHttp/Console/WebView/CapacitorCookies) — `Streamer`
/// was absent, and `Capacitor.registerPlugin` was undefined. `registerPluginInstance`
/// both adds the plugin to the bridge AND injects its JS proxy into
/// `Capacitor.Plugins.Streamer`, so the plain-HTML front end can reach it without
/// bundling `@capacitor/core`.
class MainViewController: CAPBridgeViewController {
    override open func capacitorDidLoad() {
        bridge?.registerPluginInstance(StreamerPlugin())

        // Edge-swipe back/forward (the Appilix app had this; Capacitor doesn't
        // enable it by default). The SPA uses the history API, so WKWebView's
        // back-forward gestures navigate app routes as expected.
        bridge?.webView?.allowsBackForwardNavigationGestures = true
    }
}
