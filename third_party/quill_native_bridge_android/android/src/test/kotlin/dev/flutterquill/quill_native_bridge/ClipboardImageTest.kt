package dev.flutterquill.quill_native_bridge

import android.content.ClipData
import android.content.ClipboardManager
import android.content.Context
import android.net.Uri
import dev.flutterquill.quill_native_bridge.clipboard.ClipboardReadImageHandler
import dev.flutterquill.quill_native_bridge.clipboard.ClipboardWriteImageHandler
import dev.flutterquill.quill_native_bridge.generated.FlutterError
import dev.flutterquill.quill_native_bridge.util.ImageDecoderCompat
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.RuntimeEnvironment
import org.robolectric.Shadows.shadowOf
import org.robolectric.annotation.Config
import org.robolectric.annotation.GraphicsMode
import java.io.ByteArrayInputStream
import java.io.File
import kotlin.test.assertContentEquals
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith
import kotlin.test.assertFalse
import kotlin.test.assertTrue

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [28, 35])
@GraphicsMode(GraphicsMode.Mode.NATIVE)
class ClipboardImageTest {
    private val context: Context get() = RuntimeEnvironment.getApplication()

    private fun fixture(name: String): ByteArray =
        checkNotNull(javaClass.getResourceAsStream("/images/$name")).use { it.readBytes() }

    private fun putImage(uri: Uri, mime: String) {
        val clipboard = context.getSystemService(Context.CLIPBOARD_SERVICE) as ClipboardManager
        clipboard.setPrimaryClip(ClipData("test", arrayOf(mime), ClipData.Item(uri)))
    }

    @Test
    fun `clipboard roundtrip preserves encoded formats metadata and animation`() {
        for ((name, mime) in listOf(
            "alpha.png" to "image/png",
            "rotated.jpg" to "image/jpeg",
            "alpha.webp" to "image/webp",
            "animated.gif" to "image/gif",
        )) {
            val bytes = fixture(name)
            val header = ImageDecoderCompat.readHeader(bytes)
            assertEquals(3, header.width)
            assertEquals(2, header.height)
            assertEquals(mime, header.mimeType)
            val prepared = ClipboardWriteImageHandler.writeImageFile(context.cacheDir, bytes)
            val file = prepared.file
            assertEquals(mime, prepared.mimeType)
            assertEquals(header.extension, file.extension)
            assertContentEquals(bytes, file.readBytes())
            putImage(Uri.fromFile(file), mime)
            val type = if (mime == "image/gif") {
                ClipboardReadImageHandler.ImageType.Gif
            } else {
                ClipboardReadImageHandler.ImageType.AnyExceptGif
            }
            assertContentEquals(bytes, ClipboardReadImageHandler.getClipboardImage(context, type))
        }
    }

    @Test
    fun `large image retains dimensions and compressed bytes`() {
        val bytes = fixture("large.png")
        val header = ImageDecoderCompat.readHeader(bytes)
        assertEquals(6000, header.width)
        assertEquals(4000, header.height)
        assertTrue(bytes.size < 100_000)
        val file = ClipboardWriteImageHandler.writeImageFile(context.cacheDir, bytes).file
        putImage(Uri.fromFile(file), "image/png")
        assertContentEquals(bytes, ClipboardReadImageHandler.getClipboardImage(
            context, ClipboardReadImageHandler.ImageType.AnyExceptGif,
        ))
    }

    @Test
    fun `invalid headers are rejected without creating a file`() {
        for (bytes in listOf(byteArrayOf(), "not an image".toByteArray(), fixture("alpha.png").take(12).toByteArray())) {
            assertFalse(ImageDecoderCompat.isValidImage(bytes))
            val error = assertFailsWith<FlutterError> {
                ClipboardWriteImageHandler.writeImageFile(context.cacheDir, bytes)
            }
            assertEquals("INVALID_IMAGE", error.code)
        }
    }

    @Test
    fun `missing clipboard URI is reported`() {
        putImage(Uri.fromFile(File(context.cacheDir, "missing.png")), "image/png")
        val error = assertFailsWith<FlutterError> {
            ClipboardReadImageHandler.getClipboardImage(context, ClipboardReadImageHandler.ImageType.AnyExceptGif)
        }
        assertEquals("FILE_NOT_FOUND", error.code)
    }

    @Test
    fun `provider stream is closed on successful and failed header inspection`() {
        for (bytes in listOf(fixture("alpha.png"), byteArrayOf(1, 2, 3))) {
            var closed = false
            val stream = object : ByteArrayInputStream(bytes) {
                override fun close() { closed = true; super.close() }
            }
            val uri = Uri.parse("content://test/image")
            shadowOf(context.contentResolver).registerInputStream(uri, stream)
            putImage(uri, "image/png")
            try {
                ClipboardReadImageHandler.getClipboardImage(context, ClipboardReadImageHandler.ImageType.AnyExceptGif)
            } catch (error: FlutterError) {
                assertEquals("COULD_NOT_DECODE_IMAGE", error.code)
            }
            assertTrue(closed)
        }
    }

    @Test
    fun `revoked provider permission is reported and stream is closed`() {
        var closed = false
        val stream = object : ByteArrayInputStream(fixture("alpha.png")) {
            override fun read(bytes: ByteArray, offset: Int, length: Int): Int =
                throw SecurityException("permission revoked")
            override fun close() { closed = true; super.close() }
        }
        val uri = Uri.parse("content://test/denied")
        shadowOf(context.contentResolver).registerInputStream(uri, stream)
        putImage(uri, "image/png")
        val error = assertFailsWith<FlutterError> {
            ClipboardReadImageHandler.getClipboardImage(context, ClipboardReadImageHandler.ImageType.AnyExceptGif)
        }
        assertEquals("FILE_READ_PERMISSION_DENIED", error.code)
        assertTrue(closed)
    }
}
