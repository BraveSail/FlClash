package com.follow.clash.plugins

import com.follow.clash.ServiceController
import com.follow.clash.common.Components
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.launch

/**
 * The channel the app asks the core to do something.
 *
 * The command and its answer are JSON both ways: the app sends one encoded
 * call, the core answers with one encoded response. It is the same core the
 * service channel drives - this is only the shape the newer app expects, where
 * commands and events have channels of their own instead of sharing one.
 */
class CorePlugin : FlutterPlugin, MethodChannel.MethodCallHandler {
    private lateinit var channel: MethodChannel
    private lateinit var scope: CoroutineScope

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        scope = CoroutineScope(SupervisorJob() + Dispatchers.Default)
        channel = MethodChannel(binding.binaryMessenger, "${Components.PACKAGE_NAME}/core")
        channel.setMethodCallHandler(this)
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        channel.setMethodCallHandler(null)
        scope.cancel()
    }

    override fun onMethodCall(call: MethodCall, rawResult: MethodChannel.Result) {
        val result = MainThreadResult(rawResult)
        when (call.method) {
            "invokeMethod" -> invokeMethod(call, result)
            else -> result.notImplemented()
        }
    }

    private fun invokeMethod(call: MethodCall, result: MethodChannel.Result) {
        val data = call.arguments as? String
        if (data == null) {
            result.error("INVALID_ARGUMENT", "Method call payload must be a string", null)
            return
        }
        scope.launch {
            ServiceController.invokeMethod(data) { response ->
                // Bytes, not a string: the app decodes this as a Uint8List and
                // refuses anything else - the same answer either way, but the
                // channel has one type.
                result.success(response.toByteArray(Charsets.UTF_8))
            }.onFailure { error ->
                result.error("CORE_ERROR", error.message, null)
            }
        }
    }
}
