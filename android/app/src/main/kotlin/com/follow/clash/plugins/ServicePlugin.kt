package com.follow.clash.plugins

import com.follow.clash.ServiceController
import com.follow.clash.ServiceState
import com.follow.clash.common.Components
import com.follow.clash.models.SharedState
import com.google.gson.Gson
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.launch

class ServicePlugin : FlutterPlugin, MethodChannel.MethodCallHandler {
    private lateinit var channel: MethodChannel
    private lateinit var scope: CoroutineScope
    private val gson = Gson()

    // The revision of the last command, echoed back when the service reports
    // that it stopped.
    private var revision = 0

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        scope = CoroutineScope(SupervisorJob() + Dispatchers.Default)
        channel = MethodChannel(binding.binaryMessenger, "${Components.PACKAGE_NAME}/service")
        channel.setMethodCallHandler(this)
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        channel.setMethodCallHandler(null)
        scope.cancel()
        ServiceController.setEventListener(null)
    }

    override fun onMethodCall(call: MethodCall, rawResult: MethodChannel.Result) {
        // Most handlers below reply from a scope worker on Dispatchers.Default,
        // but a MethodChannel.Result has to be answered on the platform thread.
        // Wrapping once here covers every branch, including notImplemented.
        val result = MainThreadResult(rawResult)
        when (call.method) {
            "init" -> initialize(result)
            "shutdown" -> shutdown(result)
            "invokeMethod" -> invokeMethod(call, result)
            "getRunTime" -> getRunTime(result)
            "syncState" -> syncState(call, result)
            "start" -> start(call, result)
            "stop" -> stop(call, result)
            else -> result.notImplemented()
        }
    }

    private fun initialize(result: MethodChannel.Result) {
        ServiceController.setEventListener(::sendEvent)
            .onSuccess { result.success("") }
            .onFailure { error -> result.success(error.message.orEmpty()) }
    }

    private fun shutdown(result: MethodChannel.Result) {
        scope.launch {
            ServiceController.unbind()
            result.success(true)
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
                result.success(response)
            }.onFailure { error ->
                result.error("CORE_ERROR", error.message, null)
            }
        }
    }

    private fun getRunTime(result: MethodChannel.Result) {
        scope.launch {
            result.success(ServiceState.refresh())
        }
    }

    private fun syncState(call: MethodCall, result: MethodChannel.Result) {
        val data = call.arguments as? String
        val state = runCatching {
            gson.fromJson(data, SharedState::class.java)
        }.getOrNull()
        if (state == null) {
            result.success("Invalid shared state")
            return
        }
        scope.launch {
            ServiceState.syncSharedState(state)
            result.success("")
        }
    }

    private fun start(call: MethodCall, result: MethodChannel.Result) {
        revision = call.arguments as? Int ?: revision
        ServiceState.requestStart()
        result.success(true)
    }

    private fun stop(call: MethodCall, result: MethodChannel.Result) {
        revision = call.arguments as? Int ?: revision
        val stopped = revision
        ServiceState.requestStop()
        result.success(true)
        // The app stamps each command and ignores a stop report older than the
        // one it is waiting for, so the revision it just sent is the one to
        // answer with.
        scope.launch(Dispatchers.Main) {
            channel.invokeMethod("stopped", stopped)
        }
    }

    private fun sendEvent(value: String?) {
        if (value == null) {
            return
        }
        val payload = value.toByteArray(Charsets.UTF_8)
        scope.launch(Dispatchers.Main) {
            // Bytes: the app decodes this as a Uint8List of one encoded call.
            channel.invokeMethod("event", payload)
        }
    }
}
