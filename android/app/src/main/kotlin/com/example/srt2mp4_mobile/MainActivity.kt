package com.example.srt2mp4_mobile

import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine

class MainActivity : FlutterActivity() {
    private var videoExporter: VideoExporter? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        videoExporter = VideoExporter(this, flutterEngine.dartExecutor.binaryMessenger)
    }

    override fun onDestroy() {
        videoExporter?.close()
        super.onDestroy()
    }
}
