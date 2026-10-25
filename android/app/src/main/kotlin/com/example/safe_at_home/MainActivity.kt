package com.example.safe_at_home

import android.os.Bundle
import android.content.Intent
import android.view.WindowManager
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine

class MainActivity : FlutterActivity() {
    private var bathroomScan: BathroomScanPlatform? = null
    private var assistant: PlanAssistantPlatform? = null
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        window.addFlags(WindowManager.LayoutParams.FLAG_SECURE)
    }
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        PrivateMediaPlatform(this, flutterEngine.dartExecutor.binaryMessenger).register()
        bathroomScan = BathroomScanPlatform(this, flutterEngine.dartExecutor.binaryMessenger).also { it.register() }
        assistant = PlanAssistantPlatform(this, flutterEngine.dartExecutor.binaryMessenger).also { it.register() }
    }
    override fun onResume() { super.onResume(); assistant?.onResume() }
    override fun onPause() { assistant?.onPause(); super.onPause() }
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        if (bathroomScan?.onActivityResult(requestCode, resultCode, data) != true) {
            super.onActivityResult(requestCode, resultCode, data)
        }
    }
    override fun onDestroy() {
        assistant?.detach()
        assistant = null
        bathroomScan?.detach()
        bathroomScan = null
        super.onDestroy()
    }
}
