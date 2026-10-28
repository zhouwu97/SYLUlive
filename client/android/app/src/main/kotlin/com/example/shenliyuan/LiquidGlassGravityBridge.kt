package com.example.shenliyuan

import android.app.Activity
import android.content.Context
import android.hardware.Sensor
import android.hardware.SensorEvent
import android.hardware.SensorEventListener
import android.hardware.SensorManager
import android.view.Surface
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel

/** 只传本地重力方向，监听与页面订阅和 Activity 前后台状态同时绑定。 */
class LiquidGlassGravityBridge(private val activity: Activity, messenger: BinaryMessenger) : SensorEventListener {
    private val manager = activity.getSystemService(Context.SENSOR_SERVICE) as SensorManager
    private val gravity = manager.getDefaultSensor(Sensor.TYPE_GRAVITY)
    private val events = EventChannel(messenger, "liquid_glass/gravity")
    private val capabilities = MethodChannel(messenger, "liquid_glass/capabilities")
    private var sink: EventChannel.EventSink? = null
    private var foreground = false
    init {
        capabilities.setMethodCallHandler { call, result ->
            if (call.method == "gravity") result.success(gravity != null) else result.notImplemented()
        }
        events.setStreamHandler(object : EventChannel.StreamHandler {
            override fun onListen(arguments: Any?, eventSink: EventChannel.EventSink?) {
                sink = eventSink
                if (foreground) register()
            }
            override fun onCancel(arguments: Any?) { manager.unregisterListener(this@LiquidGlassGravityBridge); sink = null }
        })
    }
    private fun register() { if (sink != null) gravity?.let { manager.registerListener(this, it, 50000) } }
    fun resume() { foreground = true; register() }
    fun pause() { foreground = false; manager.unregisterListener(this) }
    fun dispose() { pause(); sink = null; events.setStreamHandler(null); capabilities.setMethodCallHandler(null) }
    override fun onAccuracyChanged(sensor: Sensor?, accuracy: Int) = Unit
    override fun onSensorChanged(event: SensorEvent) {
        val x = event.values[0] / SensorManager.GRAVITY_EARTH
        val y = event.values[1] / SensorManager.GRAVITY_EARTH
        @Suppress("DEPRECATION") val rotation = activity.windowManager.defaultDisplay.rotation
        sink?.success(when (rotation) {
            Surface.ROTATION_90 -> listOf(-y, -x)
            Surface.ROTATION_180 -> listOf(x, -y)
            Surface.ROTATION_270 -> listOf(y, x)
            else -> listOf(-x, y)
        })
    }
}
