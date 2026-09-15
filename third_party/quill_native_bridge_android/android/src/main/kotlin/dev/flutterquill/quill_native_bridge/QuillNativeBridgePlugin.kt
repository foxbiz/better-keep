package dev.flutterquill.quill_native_bridge

import android.util.Log
import androidx.annotation.VisibleForTesting
import dev.flutterquill.quill_native_bridge.generated.QuillNativeBridgeApi
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.embedding.engine.plugins.activity.ActivityAware
import io.flutter.embedding.engine.plugins.activity.ActivityPluginBinding

class QuillNativeBridgePlugin :
    FlutterPlugin,
    ActivityAware {
    companion object {
        const val TAG = "QuillNativeBridgePlugin"
    }

    @VisibleForTesting
    internal var pluginApi: QuillNativeBridgeImpl? = null

    @VisibleForTesting
    internal var activityPluginBinding: ActivityPluginBinding? = null

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        val pluginApi = QuillNativeBridgeImpl(binding.applicationContext)
        this.pluginApi = pluginApi
        QuillNativeBridgeApi.setUp(binding.binaryMessenger, pluginApi)
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        if (pluginApi == null) {
            Log.wtf(TAG, "Already detached from the Flutter engine.")
            return
        }

        QuillNativeBridgeApi.setUp(binding.binaryMessenger, null)
        pluginApi = null
    }

    override fun onAttachedToActivity(binding: ActivityPluginBinding) {
        setActivityPluginBinding(binding, ::onAttachedToActivity.name)
    }

    override fun onDetachedFromActivityForConfigChanges() {
        disposeActivityPluginBinding(::onDetachedFromActivityForConfigChanges.name)
    }

    override fun onReattachedToActivityForConfigChanges(binding: ActivityPluginBinding) {
        setActivityPluginBinding(binding, ::onReattachedToActivityForConfigChanges.name)
    }

    override fun onDetachedFromActivity() {
        disposeActivityPluginBinding(::onDetachedFromActivity.name)
    }

    private fun logApiNotSetError(methodName: String) {
        Log.wtf(
            TAG,
            "The `${::pluginApi.name}` is not initialized. Failed to update Flutter activity binding " +
                "reference for `${QuillNativeBridgeImpl::class.simpleName}` in `$methodName`.",
        )
    }

    @VisibleForTesting
    internal fun setActivityPluginBinding(
        binding: ActivityPluginBinding,
        methodName: String,
    ) {
        activityPluginBinding = binding
        pluginApi?.setActivityPluginBinding(binding) ?: logApiNotSetError(methodName)
    }

    @VisibleForTesting
    internal fun disposeActivityPluginBinding(methodName: String) {
        activityPluginBinding = null
        pluginApi?.setActivityPluginBinding(null) ?: logApiNotSetError(methodName)
    }
}
