package dev.flutterquill.quill_native_bridge

import android.app.Activity
import android.app.Application
import io.flutter.embedding.engine.plugins.FlutterPlugin.FlutterPluginBinding
import io.flutter.embedding.engine.plugins.activity.ActivityPluginBinding
import io.flutter.plugin.common.BinaryMessenger
import org.mockito.kotlin.any
import org.mockito.kotlin.mock
import org.mockito.kotlin.times
import org.mockito.kotlin.verify
import org.mockito.kotlin.verifyNoMoreInteractions
import kotlin.test.BeforeTest
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNotNull
import kotlin.test.assertNull

class QuillNativeBridgePluginTest {
    private lateinit var mockPluginApi: QuillNativeBridgeImpl
    private lateinit var mockApplication: Application
    private lateinit var mockActivity: Activity

    private lateinit var mockFlutterPluginBinding: FlutterPluginBinding
    private lateinit var mockActivityBinding: ActivityPluginBinding
    private lateinit var mockBinaryMessenger: BinaryMessenger

    private lateinit var plugin: QuillNativeBridgePlugin

    @BeforeTest
    fun setup() {
        mockPluginApi = mock()
        mockApplication = mock()
        mockActivity = mock()
        mockBinaryMessenger = mock()
        mockFlutterPluginBinding =
            mock {
                on { applicationContext }.thenReturn(mockApplication)
                on { binaryMessenger }.thenReturn(mockBinaryMessenger)
            }
        mockActivityBinding = mock { on { activity }.thenReturn(mockActivity) }

        plugin = QuillNativeBridgePlugin()
    }

    @Test
    fun `The log tag is correct`() {
        assertEquals("QuillNativeBridgePlugin", QuillNativeBridgePlugin.TAG)
    }

    @Test
    fun `onAttachedToEngine sets up the plugin API`() {
        assertNull(plugin.pluginApi, "The plugin API is null initially")

        plugin.onAttachedToEngine(mockFlutterPluginBinding)

        verify(mockFlutterPluginBinding).binaryMessenger
        verify(mockFlutterPluginBinding).applicationContext
        verifyNoMoreInteractions(mockFlutterPluginBinding)

        assertNotNull(plugin.pluginApi, "The plugin API should be not null after the attach")
    }

    @Test
    fun `onDetachedFromEngine tears down the plugin API`() {
        plugin.onAttachedToEngine(mockFlutterPluginBinding)
        plugin.onDetachedFromEngine(mockFlutterPluginBinding)

        verify(mockFlutterPluginBinding, times(2)).binaryMessenger
        verify(mockFlutterPluginBinding).applicationContext
        verifyNoMoreInteractions(mockFlutterPluginBinding)

        assertNull(plugin.pluginApi, "The plugin API be null after the detach")
    }

    @Test
    fun `setActivityPluginBinding updates ActivityPluginBinding reference correctly`() {
        plugin.pluginApi = mockPluginApi

        assertNotNull(plugin.pluginApi, "The plugin API expected to be not null")
        assertNull(plugin.activityPluginBinding, "The activity plugin binding is null initially")

        val input = mock<ActivityPluginBinding>()

        plugin.setActivityPluginBinding(input, "Any")

        assertNotNull(plugin.activityPluginBinding)
        assertEquals(input, plugin.activityPluginBinding)

        verify(mockPluginApi).setActivityPluginBinding(input)
        verifyNoMoreInteractions(mockPluginApi)
    }

    @Test
    fun `disposeActivityPluginBinding updates ActivityPluginBinding reference to null`() {
        plugin.pluginApi = mockPluginApi

        assertNotNull(plugin.pluginApi, "The plugin API expected to be not null")
        assertNull(plugin.activityPluginBinding, "The activity plugin binding is null initially")

        plugin.setActivityPluginBinding(mock(), "Any")
        assertNotNull(plugin.activityPluginBinding)

        verify(mockPluginApi).setActivityPluginBinding(any())

        plugin.disposeActivityPluginBinding("Any")

        assertNull(plugin.activityPluginBinding)

        verify(mockPluginApi).setActivityPluginBinding(null)
        verifyNoMoreInteractions(mockPluginApi)
    }

    @Test
    fun `onAttachedToActivity updates ActivityPluginBinding reference correctly`() {
        plugin.pluginApi = mockPluginApi

        val input = mock<ActivityPluginBinding>()

        plugin.onAttachedToActivity(input)

        assertNotNull(plugin.activityPluginBinding)
        assertEquals(input, plugin.activityPluginBinding)
    }

    @Test
    fun `onDetachedFromActivityForConfigChanges updates ActivityPluginBinding reference to null`() {
        plugin.activityPluginBinding = mock()

        assertNotNull(plugin.activityPluginBinding)

        plugin.pluginApi = mockPluginApi

        plugin.onDetachedFromActivityForConfigChanges()

        assertNull(plugin.activityPluginBinding)
    }

    @Test
    fun `onReattachedToActivityForConfigChanges updates ActivityPluginBinding reference correctly`() {
        plugin.pluginApi = mockPluginApi

        val input = mock<ActivityPluginBinding>()

        plugin.onReattachedToActivityForConfigChanges(input)

        assertNotNull(plugin.activityPluginBinding)
        assertEquals(input, plugin.activityPluginBinding)
    }

    @Test
    fun `onDetachedFromActivity updates ActivityPluginBinding reference to null`() {
        plugin.activityPluginBinding = mock()

        assertNotNull(plugin.activityPluginBinding)

        plugin.pluginApi = mockPluginApi

        plugin.onDetachedFromActivity()

        assertNull(plugin.activityPluginBinding)
    }
}
