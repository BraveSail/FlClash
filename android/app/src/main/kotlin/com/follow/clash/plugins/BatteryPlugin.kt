package com.follow.clash.plugins

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.net.Uri
import android.os.Build
import android.os.PowerManager
import android.provider.Settings
import com.follow.clash.common.Components
import com.follow.clash.common.GlobalState
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

/**
 * Whether the system is allowed to put this app to sleep.
 *
 * A phone that optimises the battery kills the tunnel the moment the screen
 * goes off, and the mesh then reads as a device that vanished. The app asks
 * this channel for the current answer and for one update per change, and the
 * user grants it through the system dialog this plugin opens - the app itself
 * cannot grant it.
 */
class BatteryPlugin : FlutterPlugin, MethodChannel.MethodCallHandler, EventChannel.StreamHandler {
    private lateinit var methodChannel: MethodChannel
    private lateinit var eventChannel: EventChannel
    private var receiver: BroadcastReceiver? = null
    private var sink: EventChannel.EventSink? = null

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        val messenger = binding.binaryMessenger
        methodChannel = MethodChannel(messenger, "${Components.PACKAGE_NAME}/battery")
        methodChannel.setMethodCallHandler(this)
        eventChannel = EventChannel(messenger, "${Components.PACKAGE_NAME}/battery/optimization")
        eventChannel.setStreamHandler(this)
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        methodChannel.setMethodCallHandler(null)
        eventChannel.setStreamHandler(null)
        stopWatching()
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "requestIgnoreOptimizations" -> {
                requestIgnore(result)
            }

            "isIgnoringOptimizations" -> {
                result.success(isIgnoring())
            }

            else -> result.notImplemented()
        }
    }

    private fun requestIgnore(result: MethodChannel.Result) {
        if (isIgnoring()) {
            result.success(null)
            return
        }
        val context = GlobalState.application
        val intent = Intent(Settings.ACTION_REQUEST_IGNORE_BATTERY_OPTIMIZATIONS).apply {
            data = Uri.parse("package:${context.packageName}")
            addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        }
        runCatching { context.startActivity(intent) }
            .onSuccess { result.success(null) }
            .onFailure { result.error("NO_SETTINGS", it.message, null) }
    }

    private fun isIgnoring(): Boolean {
        val context = GlobalState.application
        val power = context.getSystemService(Context.POWER_SERVICE) as? PowerManager ?: return true
        return power.isIgnoringBatteryOptimizations(context.packageName)
    }

    override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
        sink = events
        val context = GlobalState.application
        val filter = IntentFilter().apply {
            addAction(PowerManager.ACTION_POWER_SAVE_MODE_CHANGED)
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N) {
                addAction(PowerManager.ACTION_IGNORE_BATTERY_OPTIMIZATION_SETTINGS)
            }
        }
        receiver = object : BroadcastReceiver() {
            override fun onReceive(context: Context?, intent: Intent?) {
                // The grant happens in a settings page we do not own, so the
                // answer has to be re-read rather than taken from the intent.
                events?.success(isIgnoring())
            }
        }.also { context.registerReceiver(it, filter) }
        events?.success(isIgnoring())
    }

    override fun onCancel(arguments: Any?) {
        stopWatching()
    }

    private fun stopWatching() {
        sink = null
        receiver?.let { runCatching { GlobalState.application.unregisterReceiver(it) } }
        receiver = null
    }
}
