package com.example.bottom_nav_demo

import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel
import android.hardware.Sensor
import android.hardware.SensorEvent
import android.hardware.SensorEventListener
import android.hardware.SensorManager
import android.view.Surface

class MainActivity : FlutterActivity(), SensorEventListener {
    private var sensorManager: SensorManager? = null
    private var gravity: Sensor? = null
    private var sink: EventChannel.EventSink? = null
    private var channel: EventChannel? = null
    private var capabilities: MethodChannel? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        sensorManager = getSystemService(SENSOR_SERVICE) as SensorManager
        gravity = sensorManager?.getDefaultSensor(Sensor.TYPE_GRAVITY)
        capabilities = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "liquid_glass/capabilities")
        capabilities?.setMethodCallHandler { call, result ->
            if (call.method == "gravity") result.success(gravity != null) else result.notImplemented()
        }
        channel = EventChannel(flutterEngine.dartExecutor.binaryMessenger, "liquid_glass/gravity")
        channel?.setStreamHandler(object : EventChannel.StreamHandler {
            override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
                sink = events
                gravity?.let { sensorManager?.registerListener(this@MainActivity, it, 50000) }
            }
            override fun onCancel(arguments: Any?) {
                sensorManager?.unregisterListener(this@MainActivity)
                sink = null
            }
        })
    }
    override fun onSensorChanged(event: SensorEvent) {
        val x = event.values[0] / SensorManager.GRAVITY_EARTH
        val y = event.values[1] / SensorManager.GRAVITY_EARTH
        @Suppress("DEPRECATION")
        val rotation = windowManager.defaultDisplay.rotation
        val vector = when (rotation) {
            Surface.ROTATION_90 -> listOf(-y, -x)
            Surface.ROTATION_180 -> listOf(x, -y)
            Surface.ROTATION_270 -> listOf(y, x)
            else -> listOf(-x, y)
        }
        sink?.success(vector)
    }
    override fun onAccuracyChanged(sensor: Sensor?, accuracy: Int) = Unit
    override fun onPause() {
        sensorManager?.unregisterListener(this)
        super.onPause()
    }
    override fun onResume() {
        super.onResume()
        if (sink != null) gravity?.let { sensorManager?.registerListener(this, it, 50000) }
    }
    override fun cleanUpFlutterEngine(flutterEngine: FlutterEngine) {
        sensorManager?.unregisterListener(this)
        channel?.setStreamHandler(null)
        capabilities?.setMethodCallHandler(null)
        sink = null
        super.cleanUpFlutterEngine(flutterEngine)
    }
}
