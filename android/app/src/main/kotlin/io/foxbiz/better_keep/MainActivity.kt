package io.foxbiz.better_keep

import android.content.Intent
import android.graphics.Color
import android.os.Bundle
import androidx.core.view.WindowCompat
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import java.util.UUID

class MainActivity : FlutterActivity() {
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        AssistantNotesChannelBridge.configure(flutterEngine.dartExecutor.binaryMessenger)
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        // Enable edge-to-edge for backward compatibility (pre-Android 15).
        // On Android 15+ (SDK 35+), edge-to-edge is enforced by the system.
        WindowCompat.setDecorFitsSystemWindows(window, false)
        window.statusBarColor = Color.TRANSPARENT
        window.navigationBarColor = Color.TRANSPARENT
        handleAssistantIntent(intent)
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        handleAssistantIntent(intent)
    }

    private fun handleAssistantIntent(intent: Intent?) {
        intent ?: return
        val request = AssistantNoteIntentParser.parse(
            action = intent.action,
            mimeType = intent.type,
            title = intent.getStringExtra(AssistantNoteIntentParser.EXTRA_NAME),
            text = intent.getStringExtra(AssistantNoteIntentParser.EXTRA_TEXT),
            alreadyConsumed = intent.getBooleanExtra(
                AssistantNoteIntentParser.EXTRA_CONSUMED,
                false,
            ),
            requestId = { UUID.randomUUID().toString() },
        ) ?: return

        intent.putExtra(AssistantNoteIntentParser.EXTRA_CONSUMED, true)
        AssistantNotesChannelBridge.submit(request)
    }
}
