package dev.flutterquill.quill_native_bridge.saveImage

import android.content.ContentValues
import android.content.Context
import android.content.pm.PackageManager
import android.media.MediaScannerConnection
import android.os.Build
import android.os.Environment
import android.os.Handler
import android.os.Looper
import android.provider.MediaStore
import android.util.Log
import androidx.core.app.ActivityCompat
import androidx.core.content.ContextCompat
import dev.flutterquill.quill_native_bridge.QuillNativeBridgePlugin
import dev.flutterquill.quill_native_bridge.util.ImageDecoderCompat
import dev.flutterquill.quill_native_bridge.util.respondFlutterPigeonError
import dev.flutterquill.quill_native_bridge.util.respondFlutterPigeonSuccess
import io.flutter.embedding.engine.plugins.activity.ActivityPluginBinding
import io.flutter.plugin.common.PluginRegistry
import java.io.File
import java.io.IOException
import java.nio.file.Paths
import java.util.UUID

object SaveImageHandler {
    /**
     * @return `true` if running on API 29 or newer version.
     * */
    private fun supportsScopedStorage(): Boolean = Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q

    private const val WRITE_TO_EXTERNAL_STORAGE_REQUEST_CODE =
        449612150 // A unique code to distinguish between requests

    private const val WRITE_EXTERNAL_STORAGE_PERMISSION_NAME =
        android.Manifest.permission.WRITE_EXTERNAL_STORAGE

    private fun isWriteExternalStoragePermissionDeclared(context: Context): Boolean {
        return try {
            val packageInfo =
                context.packageManager.getPackageInfo(
                    context.packageName,
                    PackageManager.GET_PERMISSIONS,
                )
            val permissions = packageInfo.requestedPermissions

            if (permissions.isNullOrEmpty()) {
                return false
            }
            return permissions.contains(WRITE_EXTERNAL_STORAGE_PERMISSION_NAME)
        } catch (e: PackageManager.NameNotFoundException) {
            false
        }
    }

    /**
     * Write an image to the gallery with external storage permission for only Android API 28 and earlier.
     * */
    private fun saveImageToGalleryLegacy(
        imageBytes: ByteArray,
        name: String,
        albumName: String?,
        fileExtension: String,
        callback: (Result<Unit>) -> Unit,
        mimeType: String,
        context: Context,
    ) {
        val imageSaveDirectory =
            if (albumName != null) {
                File(
                    Environment.getExternalStoragePublicDirectory(Environment.DIRECTORY_PICTURES),
                    albumName,
                )
            } else {
                Environment.getExternalStoragePublicDirectory(Environment.DIRECTORY_PICTURES)
            }

        if (!imageSaveDirectory.exists() && !imageSaveDirectory.mkdirs()) {
            callback.respondFlutterPigeonError(
                "DIRECTORY_CREATION_FAILED",
                "Failed to create directory: ${imageSaveDirectory.absolutePath}",
                null,
            )
            return
        }

        val imageFile =
            File(
                imageSaveDirectory,
                "$name-${System.currentTimeMillis()}-${UUID.randomUUID()}.$fileExtension",
            )
        if (imageFile.exists()) {
            callback.respondFlutterPigeonError(
                "FILE_EXISTS",
                "A file with the name `$imageFile` already exists.",
                null,
            )
            return
        }

        imageFile.outputStream().use { outputStream ->
            try {
                outputStream.write(imageBytes)
            } catch (e: IOException) {
                callback.respondFlutterPigeonError(
                    "SAVE_FAILED",
                    "Failed to save the image to the gallery: ${e.message}",
                    e.toString(),
                )
                return
            }
        }

        MediaScannerConnection.scanFile(
            context,
            arrayOf(imageFile.absolutePath),
            arrayOf(mimeType),
            null,
        )

        callback.respondFlutterPigeonSuccess(Unit)
    }

    fun saveImageToGallery(
        context: Context,
        activityPluginBinding: ActivityPluginBinding,
        imageBytes: ByteArray,
        name: String,
        fileExtension: String,
        mimeType: String,
        albumName: String?,
        callback: (Result<Unit>) -> Unit,
    ) {
        if (!ImageDecoderCompat.isValidImage(imageBytes)) {
            callback.respondFlutterPigeonError(
                "INVALID_IMAGE",
                "The provided image bytes are invalid. Image could not be decoded.",
            )
            return
        }

        if (!supportsScopedStorage()) {
            if (!isWriteExternalStoragePermissionDeclared(context)) {
                callback.respondFlutterPigeonError(
                    "ANDROID_MANIFEST_NOT_CONFIGURED",
                    "The uses-permission '${WRITE_EXTERNAL_STORAGE_PERMISSION_NAME}' is not declared in AndroidManifest.xml",
                    "The app is running on Android API ${Build.VERSION.SDK_INT}. Scoped storage" +
                        " was introduced in ${Build.VERSION_CODES.Q} and is not available on this version.\n" +
                        "Write to external storage permission is required to save an image to the gallery.",
                )
                return
            }
            // Need to request runtime permission for API 28 and older versions
            val hasNecessaryPermission =
                ContextCompat.checkSelfPermission(
                    context,
                    android.Manifest.permission.WRITE_EXTERNAL_STORAGE,
                ) == PackageManager.PERMISSION_GRANTED
            if (!hasNecessaryPermission) {
                ActivityCompat.requestPermissions(
                    activityPluginBinding.activity,
                    arrayOf(WRITE_EXTERNAL_STORAGE_PERMISSION_NAME),
                    WRITE_TO_EXTERNAL_STORAGE_REQUEST_CODE,
                )

                activityPluginBinding.addRequestPermissionsResultListener(
                    object :
                        PluginRegistry.RequestPermissionsResultListener {
                        override fun onRequestPermissionsResult(
                            requestCode: Int,
                            permissions: Array<out String>,
                            grantResults: IntArray,
                        ): Boolean {
                            try {
                                if (requestCode != WRITE_TO_EXTERNAL_STORAGE_REQUEST_CODE) {
                                    return false
                                }
                                val isWriteExternalStoragePermissionRequested =
                                    permissions.contentEquals(
                                        arrayOf(WRITE_EXTERNAL_STORAGE_PERMISSION_NAME),
                                    )
                                if (!isWriteExternalStoragePermissionRequested) {
                                    Log.w(
                                        QuillNativeBridgePlugin.TAG,
                                        "Unexpected permissions requested. Expected only [$WRITE_EXTERNAL_STORAGE_PERMISSION_NAME], but received: ${permissions.joinToString()}.",
                                    )
                                }
                                val isGranted =
                                    grantResults.isNotEmpty() && grantResults.first() == PackageManager.PERMISSION_GRANTED
                                if (!isGranted) {
                                    callback.respondFlutterPigeonError(
                                        "PERMISSION_DENIED",
                                        "Write to external storage permission request has been denied.",
                                    )
                                    return true
                                }
                                saveImageToGalleryLegacy(
                                    imageBytes = imageBytes,
                                    name = name,
                                    albumName = albumName,
                                    fileExtension = fileExtension,
                                    callback = callback,
                                    mimeType = mimeType,
                                    context = context,
                                )
                                return true
                            } finally {
                                Handler(Looper.getMainLooper()).post {
                                    activityPluginBinding.removeRequestPermissionsResultListener(this)
                                }
                            }
                        }
                    },
                )
                return
            }

            saveImageToGalleryLegacy(
                imageBytes = imageBytes,
                name = name,
                albumName = albumName,
                fileExtension = fileExtension,
                callback = callback,
                mimeType = mimeType,
                context = context,
            )
            return
        }

        // Scoped Storage is enforced

        val contentResolver = context.contentResolver

        val contentValues =
            ContentValues().apply {
                put(MediaStore.Images.Media.DISPLAY_NAME, name)
                put(MediaStore.Images.Media.MIME_TYPE, mimeType)
                put(MediaStore.Images.Media.IS_PENDING, 1)

                albumName?.let {
                    put(
                        MediaStore.Images.Media.RELATIVE_PATH,
                        Paths.get(Environment.DIRECTORY_PICTURES, it).toString(),
                    )
                }
            }

        val imageUri =
            contentResolver.insert(MediaStore.Images.Media.EXTERNAL_CONTENT_URI, contentValues)
                ?: run {
                    callback.respondFlutterPigeonError(
                        "FAILED_TO_INSERT_IMAGE",
                        "Either the underlying content provider returns `null` or the provider crashes.",
                    )
                    return
                }

        fun notifyImageUpdate() {
            contentValues.clear()
            contentValues.put(MediaStore.Images.Media.IS_PENDING, 0)
            val rowsUpdated = contentResolver.update(imageUri, contentValues, null, null)
            if (rowsUpdated == 0) {
                Log.e(
                    QuillNativeBridgePlugin.TAG,
                    "Failed to update image state for URI: $imageUri",
                )
            }
        }

        val outputStream =
            contentResolver.openOutputStream(imageUri) ?: run {
                callback.respondFlutterPigeonError(
                    "SAVE_FAILED",
                    "Could not open the output stream. The provider might have recently crashed.",
                )
                notifyImageUpdate()
                return
            }

        try {
            outputStream.use { stream -> stream.write(imageBytes) }
            notifyImageUpdate()
            callback.respondFlutterPigeonSuccess(Unit)
        } catch (e: IOException) {
            callback.respondFlutterPigeonError(
                "SAVE_FAILED",
                "Failed to save the image to the gallery: ${e.message}",
                e.toString(),
            )
            notifyImageUpdate()
        }
    }
}
