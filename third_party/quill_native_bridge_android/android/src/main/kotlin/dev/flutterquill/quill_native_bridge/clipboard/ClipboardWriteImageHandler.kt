package dev.flutterquill.quill_native_bridge.clipboard

import android.content.ClipData
import android.content.ClipboardManager
import android.content.Context
import androidx.core.content.FileProvider
import dev.flutterquill.quill_native_bridge.generated.FlutterError
import dev.flutterquill.quill_native_bridge.util.ImageDecoderCompat
import java.io.File
import java.io.IOException

object ClipboardWriteImageHandler {
    fun copyImageToClipboard(
        context: Context,
        imageBytes: ByteArray,
    ) {
        val preparedImage = writeImageFile(context.cacheDir, imageBytes)

        val authority = "${context.packageName}.fileprovider"

        val imageUri =
            try {
                FileProvider.getUriForFile(
                    context,
                    authority,
                    preparedImage.file,
                )
            } catch (e: IllegalArgumentException) {
                throw FlutterError(
                    "ANDROID_MANIFEST_NOT_CONFIGURED",
                    "You need to configure your AndroidManifest.xml file " +
                        "to register the provider with the meta-data with authority " +
                        authority,
                    e.toString(),
                )
            }

        try {
            val clipboard =
                context.getSystemService(Context.CLIPBOARD_SERVICE) as ClipboardManager
            // Some older MIME tables omit formats supported by the decoder.
            val clip = ClipData("Image", arrayOf(preparedImage.mimeType), ClipData.Item(imageUri))
            clipboard.setPrimaryClip(clip)

            // Don't delete the temporary image file, other apps will be unable to retrieve the image
            // tempImageFile.delete()
        } catch (e: Exception) {
            throw FlutterError(
                "COULD_NOT_COPY_IMAGE_TO_CLIPBOARD",
                "Unknown error while copying the image to the clipboard: ${e.message}",
                e.toString(),
            )
        }
    }
    internal data class PreparedImage(val file: File, val mimeType: String)

    internal fun writeImageFile(cacheDir: File, imageBytes: ByteArray): PreparedImage {
        val header = try {
            ImageDecoderCompat.readHeader(imageBytes).also { it.extension }
        } catch (e: IOException) {
            throw FlutterError("INVALID_IMAGE", "Invalid image: ${e.message}", e.toString())
        }

        val tempImageFile = File(cacheDir, "temp_clipboard_image.${header.extension}")
        try {
            tempImageFile.outputStream().use { it.write(imageBytes) }
        } catch (e: Exception) {
            throw FlutterError(
                "COULD_NOT_SAVE_TEMP_FILE",
                "Could not save the temporary clipboard image: ${e.message}",
                e.toString(),
            )
        }

        if (!tempImageFile.exists()) {
            throw FlutterError(
                "TEMP_FILE_NOT_FOUND",
                "Recently created temporary file for copying the image to the clipboard is missing.",
                null,
            )
        }

        return PreparedImage(tempImageFile, header.mimeType)
    }
}
