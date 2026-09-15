package dev.flutterquill.quill_native_bridge

import android.content.Context
import android.content.Intent
import android.provider.MediaStore
import dev.flutterquill.quill_native_bridge.clipboard.ClipboardReadImageHandler
import dev.flutterquill.quill_native_bridge.clipboard.ClipboardRichTextHandler
import dev.flutterquill.quill_native_bridge.clipboard.ClipboardWriteImageHandler
import dev.flutterquill.quill_native_bridge.generated.QuillNativeBridgeApi
import dev.flutterquill.quill_native_bridge.saveImage.SaveImageHandler
import io.flutter.embedding.engine.plugins.activity.ActivityPluginBinding

class QuillNativeBridgeImpl(
    private val context: Context,
) : QuillNativeBridgeApi {
    private var activityPluginBinding: ActivityPluginBinding? = null

    override fun getClipboardHtml(): String? = ClipboardRichTextHandler.getClipboardHtml(context)

    override fun copyHtmlToClipboard(html: String) = ClipboardRichTextHandler.copyHtmlToClipboard(context, html)

    override fun getClipboardImage(): ByteArray? =
        ClipboardReadImageHandler.getClipboardImage(
            context,
            // Will convert the image to PNG
            imageType = ClipboardReadImageHandler.ImageType.AnyExceptGif,
        )

    override fun copyImageToClipboard(imageBytes: ByteArray) = ClipboardWriteImageHandler.copyImageToClipboard(context, imageBytes)

    override fun getClipboardGif(): ByteArray? =
        ClipboardReadImageHandler.getClipboardImage(
            context,
            imageType = ClipboardReadImageHandler.ImageType.Gif,
        )

    override fun openGalleryApp() {
        // TODO(save-image): Test on Android marshmallow (API 23)
        val intent =
            Intent(Intent.ACTION_VIEW, MediaStore.Images.Media.EXTERNAL_CONTENT_URI).apply {
                flags = Intent.FLAG_ACTIVITY_NEW_TASK
            }
        getActivityPluginBindingOrThrow().activity.startActivity(intent)
    }

    override fun saveImageToGallery(
        imageBytes: ByteArray,
        name: String,
        fileExtension: String,
        mimeType: String,
        albumName: String?,
        callback: (Result<Unit>) -> Unit,
    ) = SaveImageHandler.saveImageToGallery(
        context,
        getActivityPluginBindingOrThrow(),
        imageBytes = imageBytes,
        name = name,
        fileExtension = fileExtension,
        mimeType = mimeType,
        albumName = albumName,
        callback = callback,
    )

    private fun getActivityPluginBindingOrThrow(): ActivityPluginBinding =
        activityPluginBinding
            ?: throw IllegalStateException(
                "The Flutter activity binding was not set. This indicates a bug in `${QuillNativeBridgePlugin::class.simpleName}`.",
            )

    fun setActivityPluginBinding(activityPluginBinding: ActivityPluginBinding?) {
        this.activityPluginBinding = activityPluginBinding
    }
}
