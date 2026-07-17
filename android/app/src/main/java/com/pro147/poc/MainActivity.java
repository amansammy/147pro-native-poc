package com.pro147.poc;

import android.os.Bundle;
import com.getcapacitor.BridgeActivity;

public class MainActivity extends BridgeActivity {
    @Override
    public void onCreate(Bundle savedInstanceState) {
        // App-local plugins aren't auto-discovered when the web app is loaded from a
        // REMOTE origin (capacitor server.url), so register the Streamer plugin
        // explicitly. Must be called BEFORE super.onCreate so the bridge picks it up.
        registerPlugin(StreamerPlugin.class);
        super.onCreate(savedInstanceState);
    }
}
