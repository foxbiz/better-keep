package dev.flutterquill.quill_native_bridge.util

import android.graphics.BitmapFactory
import android.webkit.MimeTypeMap
import java.io.IOException

/** Inspects encoded images without allocating a width × height pixel buffer. */
object ImageDecoderCompat {
    data class ImageHeader(val width: Int, val height: Int, val mimeType: String) {
        val extension: String
            get() = when (mimeType) {
                "image/png" -> "png"
                "image/jpeg" -> "jpg"
                "image/webp" -> "webp"
                "image/gif" -> "gif"
                else -> MimeTypeMap.getSingleton().getExtensionFromMimeType(mimeType)
                    ?: throw IOException("Unsupported image MIME type: $mimeType")
            }
    }

    @Throws(IOException::class)
    fun readHeader(imageBytes: ByteArray): ImageHeader {
        val options = BitmapFactory.Options().apply { inJustDecodeBounds = true }
        BitmapFactory.decodeByteArray(imageBytes, 0, imageBytes.size, options)
        val mimeType = options.outMimeType
        if (options.outWidth <= 0 || options.outHeight <= 0 || mimeType == null) {
            throw IOException("Image header could not be decoded.")
        }
        return ImageHeader(options.outWidth, options.outHeight, mimeType)
    }

    fun isValidImage(imageBytes: ByteArray): Boolean =
        try {
            readHeader(imageBytes)
            true
        } catch (_: IOException) {
            false
        }
}
