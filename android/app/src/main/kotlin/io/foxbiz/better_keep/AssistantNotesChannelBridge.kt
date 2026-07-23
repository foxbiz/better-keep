package io.foxbiz.better_keep

import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.util.ArrayDeque

/** Keeps assistant payloads in process memory until Flutter is ready. */
object AssistantNotesChannelBridge {
    private const val CHANNEL_NAME = "io.foxbiz.better_keep/assistant_notes"

    private val pending = ArrayDeque<AssistantNoteRequest>()
    private var channel: MethodChannel? = null
    private var dartReady = false
    private var submitting = false

    fun configure(messenger: BinaryMessenger) {
        channel?.setMethodCallHandler(null)
        channel = MethodChannel(messenger, CHANNEL_NAME).also {
            it.setMethodCallHandler(::handleDartCall)
        }
        dartReady = false
    }

    fun submit(request: AssistantNoteRequest) {
        pending.addLast(request)
        flush()
    }

    private fun handleDartCall(call: MethodCall, result: MethodChannel.Result) {
        if (call.method != "ready") {
            result.notImplemented()
            return
        }
        dartReady = true
        result.success(null)
        flush()
    }

    private fun flush() {
        val activeChannel = channel ?: return
        if (!dartReady || submitting) return
        val request = pending.pollFirst() ?: return

        submitting = true
        activeChannel.invokeMethod(
            "createNote",
            buildMap<String, Any> {
                put("requestId", request.requestId)
                put("source", request.source)
                request.title?.let { put("title", it) }
                request.text?.let { put("text", it) }
            },
            object : MethodChannel.Result {
                override fun success(result: Any?) = completeSubmission()

                override fun error(code: String, message: String?, details: Any?) =
                    completeSubmission()

                override fun notImplemented() = completeSubmission()
            },
        )
    }

    private fun completeSubmission() {
        submitting = false
        flush()
    }
}
