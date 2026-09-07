package dev.flutterquill.quill_native_bridge

import dev.flutterquill.quill_native_bridge.generated.FlutterError
import dev.flutterquill.quill_native_bridge.util.respondFlutterPigeonError
import dev.flutterquill.quill_native_bridge.util.respondFlutterPigeonSuccess
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertIs
import kotlin.test.assertTrue

class FlutterPigeonResponseTest {
    @Test
    fun `respondFlutterPigeonSuccess invokes with success result correctly`() {
        var invoked = false
        val messageInput = "Hello, World!"

        val callback: (Result<String>) -> Unit = {
            invoked = true

            assertTrue(it.isSuccess)
            assertEquals(messageInput, it.getOrNull())
        }

        callback.respondFlutterPigeonSuccess(messageInput)

        assertTrue(invoked)
    }

    @Test
    fun `respondFlutterPigeonError invokes with error result correctly`() {
        var invoked = false
        val flutterPigeonError = FlutterError("EXAMPLE_CODE", "Example message", "Example Details")

        val callback: (Result<FlutterError>) -> Unit = {
            invoked = true

            assertTrue(it.isFailure)

            val capturedFlutterPigeonError = it.exceptionOrNull()
            assertIs<FlutterError>(capturedFlutterPigeonError)

            assertEquals(flutterPigeonError.code, capturedFlutterPigeonError.code)
            assertEquals(flutterPigeonError.message, capturedFlutterPigeonError.message)
            assertEquals(flutterPigeonError.details, capturedFlutterPigeonError.details)
        }

        callback.respondFlutterPigeonError(
            code = flutterPigeonError.code,
            message = flutterPigeonError.message,
            details = flutterPigeonError.details,
        )

        assertTrue(invoked)
    }
}
