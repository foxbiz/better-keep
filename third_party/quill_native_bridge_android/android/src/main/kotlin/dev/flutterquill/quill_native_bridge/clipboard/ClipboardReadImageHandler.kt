package dev.flutterquill.quill_native_bridge.clipboard

import android.content.ClipData
import android.content.ClipboardManager
import android.content.Context
import android.net.Uri
import dev.flutterquill.quill_native_bridge.generated.FlutterError
import dev.flutterquill.quill_native_bridge.util.ImageDecoderCompat
import java.io.FileNotFoundException
import java.io.IOException

object ClipboardReadImageHandler {
    private const val MIME_TYPE_IMAGE_ALL = "image/*"
    private const val MIME_TYPE_IMAGE_PNG = "image/png"
    private const val MIME_TYPE_IMAGE_JPEG = "image/jpeg"
    private const val MIME_TYPE_IMAGE_GIF = "image/gif"

    /**
     * The media/image type.
     *
     * @property Png [MIME_TYPE_IMAGE_PNG]
     * @property AnyExceptGif All images that are [MIME_TYPE_IMAGE_ALL] but not [MIME_TYPE_IMAGE_GIF]
     * @property Gif [MIME_TYPE_IMAGE_GIF]
     * @property Jpeg [MIME_TYPE_IMAGE_JPEG]
     * */
    enum class ImageType { Png, Jpeg, AnyExceptGif, Gif }

    /**
     * Read the primary clip of the system clipboard using [ClipboardManager]
     * */
    private fun getPrimaryClip(context: Context): ClipData? {
        val clipboard =
            context.getSystemService(Context.CLIPBOARD_SERVICE) as ClipboardManager

        if (!clipboard.hasPrimaryClip()) {
            return null
        }

        val clipData = clipboard.primaryClip

        if (clipData == null || clipData.itemCount <= 0) {
            return null
        }

        return clipData
    }

    /**
     * Return Image URI from [clipData].
     *
     * If the [ClipData.Item.getUri] is `null` then will check if the [clipData]
     * is a text containing the file path, parse it and return the [Uri].
     *
     * Opening a non-null [Uri] can still fail if the app no longer has read access.
     *
     * @param clipData The clip data to extract the [Uri] from.
     * @param imageType The type of the image whatever if it's png, gif or any.
     * */
    private fun getImageUri(
        clipData: ClipData,
        imageType: ImageType,
    ): Uri? {
        val clipboardItem = clipData.getItemAt(0)

        val imageUri = clipboardItem.uri
        val matchMimeType: Boolean =
            when (imageType) {
                ImageType.Png -> clipData.description.hasMimeType(MIME_TYPE_IMAGE_PNG)
                ImageType.Jpeg -> clipData.description.hasMimeType(MIME_TYPE_IMAGE_JPEG)
                ImageType.AnyExceptGif ->
                    clipData.description.hasMimeType(MIME_TYPE_IMAGE_ALL) &&
                        !clipData.description.hasMimeType(MIME_TYPE_IMAGE_GIF)

                ImageType.Gif -> clipData.description.hasMimeType(MIME_TYPE_IMAGE_GIF)
            }
        if (imageUri == null || !matchMimeType) {
            // Image URI is null or the mime type doesn't match.
            // This is not widely supported but some apps do store images as file paths in a text

            // Optional: Check if the clipboard item contains text that might be a file path
            val text = clipboardItem.text ?: return null
            if (!text.startsWith("file://")) {
                return null
            }
            val fileUri = Uri.parse(text.toString())
            return try {
                fileUri
            } catch (e: Exception) {
                e.printStackTrace()
                null
            }
        }
        return imageUri
    }

    /**
     * Get the clipboard Image.
     * */
    fun getClipboardImage(
        context: Context,
        imageType: ImageType,
    ): ByteArray? {
        val primaryClipData = getPrimaryClip(context) ?: return null

        val imageUri =
            getImageUri(
                clipData = primaryClipData,
                imageType = imageType,
            ) ?: return null

        return try {
            val bytes = checkNotNull(context.contentResolver.openInputStream(imageUri)) {
                "The clipboard image provider returned no stream."
            }.use { it.readBytes() }
            // Preserve the source format, EXIF, alpha and animation. The Dart API
            // accepts encoded image bytes and does not require a PNG conversion.
            ImageDecoderCompat.readHeader(bytes)
            bytes
        } catch (e: Exception) {
            val code = when (e) {
                is SecurityException -> "FILE_READ_PERMISSION_DENIED"
                is FileNotFoundException -> "FILE_NOT_FOUND"
                is IOException -> "COULD_NOT_DECODE_IMAGE"
                else -> "UNKNOWN_ERROR_READING_FILE"
            }
            throw FlutterError(code, "Could not read clipboard image: ${e.message}", e.toString())
        }
    }
}
