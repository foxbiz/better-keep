package io.foxbiz.better_keep

import android.content.pm.ActivityInfo
import android.content.res.Configuration
import android.graphics.Color
import android.os.Build
import android.os.Bundle
import android.os.StatFs
import android.view.WindowManager
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
        configureOrientation(resources.configuration)
        configureEdgeToEdge()
    }

    override fun onConfigurationChanged(newConfig: Configuration) {
        super.onConfigurationChanged(newConfig)
        configureOrientation(newConfig)
    }

    private fun configureOrientation(configuration: Configuration) {
        // Let the system own rotation while the activity is in a managed window.
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N &&
            (isInMultiWindowMode || isInPictureInPictureMode)
        ) return
        // Keep phones upright; tablets and unfolded large screens can rotate.
        val orientation = if (configuration.smallestScreenWidthDp >= 600) {
            ActivityInfo.SCREEN_ORIENTATION_FULL_USER
        } else {
            ActivityInfo.SCREEN_ORIENTATION_PORTRAIT
        }
        if (requestedOrientation != orientation) {
            requestedOrientation = orientation
        }
    }

    @Suppress("DEPRECATION")
    private fun configureEdgeToEdge() {
        WindowCompat.setDecorFitsSystemWindows(window, false)

        // AndroidX Core 1.18's enableEdgeToEdge calls these deprecated APIs on
        // every OS version. Only older Android versions need transparent bars.
        if (Build.VERSION.SDK_INT < 35) {
            window.statusBarColor = Color.TRANSPARENT
            window.navigationBarColor = Color.TRANSPARENT
        }

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
            window.attributes = window.attributes.apply {
                layoutInDisplayCutoutMode = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
                    WindowManager.LayoutParams.LAYOUT_IN_DISPLAY_CUTOUT_MODE_ALWAYS
                } else {
                    WindowManager.LayoutParams.LAYOUT_IN_DISPLAY_CUTOUT_MODE_SHORT_EDGES
                }
            }
        }

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            window.isStatusBarContrastEnforced = false
            window.isNavigationBarContrastEnforced = false
        }
    }
}
