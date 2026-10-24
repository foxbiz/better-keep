package io.foxbiz.better_keep

import android.os.Bundle
import android.os.StatFs
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import androidx.core.view.WindowCompat
import io.flutter.embedding.android.FlutterActivity

class MainActivity : FlutterActivity() {
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "com.betterkeep/storage")
            .setMethodCallHandler { call, result ->
                if (call.method != "getAvailableBytes") {
                    result.notImplemented()
                } else {
                    try {
                        val path = call.arguments as? String ?: filesDir.path
                        result.success(StatFs(path).availableBytes)
                    } catch (error: Exception) {
                        result.error("storage_unavailable", "Storage information is unavailable", null)
                    }
                }
            }
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        WindowCompat.enableEdgeToEdge(window)
    }
}
