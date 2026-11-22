package com.community.flutter.stampcomposite

import android.app.Activity
import android.content.Context
import android.media.MediaActionSound
import android.os.Handler
import android.os.Looper
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.embedding.engine.plugins.activity.ActivityAware
import io.flutter.embedding.engine.plugins.activity.ActivityPluginBinding
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.util.concurrent.ExecutorService
import java.util.concurrent.Executors

/**
 * Native JPEG composite for GPS-stamp photos. Every decode / draw / encode / EXIF step runs on ONE background
 * executor (composites are serialized: two 48 MP decodes never overlap); the reply is posted to the main
 * looper. The platform thread only parses arguments and enqueues.
 *
 * `mapAvailable` / `mapSnapshot`: the Google Maps lite-mode mini-map ([MapSnapshot]); available only when
 * the app's manifest carries a Maps API key.
 */
class CommunityFlutterStampCompositePlugin : FlutterPlugin, MethodChannel.MethodCallHandler, ActivityAware {
    private var channel: MethodChannel? = null
    private var context: Context? = null
    private var activity: Activity? = null

    /** In-flight map snapshots: cancelled on any detach, so none outlives its activity or engine. */
    private val snapshots = SnapshotCalls()
    private var executor: ExecutorService? = null
    private val main = Handler(Looper.getMainLooper())

    /** The system camera shutter click (the camera stack takes pictures silently on Android). */
    private var shutter: MediaActionSound? = null

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        context = binding.applicationContext
        executor = Executors.newSingleThreadExecutor { r -> Thread(r, "stamp-composite") }
        channel = MethodChannel(binding.binaryMessenger, "community_flutter_stamp_composite").also { it.setMethodCallHandler(this) }
        shutter = MediaActionSound().also { it.load(MediaActionSound.SHUTTER_CLICK) }
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        // The engine is gone: tear the map views down and never touch their replies (dead messenger).
        snapshots.cancelAll(reply = false)
        channel?.setMethodCallHandler(null)
        channel = null
        executor?.shutdown()
        executor = null
        shutter?.release()
        shutter = null
        context = null
    }

    override fun onAttachedToActivity(binding: ActivityPluginBinding) { activity = binding.activity }
    override fun onReattachedToActivityForConfigChanges(binding: ActivityPluginBinding) { activity = binding.activity }

    // The map views live in the activity's window: when it goes, cancel them. The engine still runs here, so the Dart
    // side gets an error reply (its future completes; the stamp stays text only).
    override fun onDetachedFromActivityForConfigChanges() = detachActivity()
    override fun onDetachedFromActivity() = detachActivity()

    private fun detachActivity() {
        snapshots.cancelAll(reply = channel != null)
        activity = null
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "orientedSize" -> {
                val path = call.argument<String>("path")
                if (path == null) { result.error("COMPOSITE", "path is required", null); return }
                runInBackground(result) { StampCompositeJob.orientedSize(path) }
            }
            "composite" -> {
                val args = call.arguments as? Map<*, *>
                if (args == null || args["src"] !is String || args["out"] !is String || args["outWidth"] !is Number || args["outHeight"] !is Number) {
                    result.error("COMPOSITE", "src, out, outWidth and outHeight are required", null); return
                }
                runInBackground(result) { StampCompositeJob(args).run() }
            }
            "shutterSound" -> {
                shutter?.play(MediaActionSound.SHUTTER_CLICK)
                result.success(null)
            }
            "mapAvailable" -> result.success(context?.let { MapSnapshot.isAvailable(it) } ?: false)
            "mapSnapshot" -> {
                val ctx = context
                val ex = executor
                val args = call.arguments as? Map<*, *>
                if (ctx == null || ex == null) { result.error("COMPOSITE", "plugin detached", null); return }
                if (args == null) { result.error("COMPOSITE", "lat and lon are required", null); return }
                val call = SnapshotCall { outcome ->
                    // Never reply through a detached engine (onDetachedFromEngine cancels silently; this is the guard).
                    if (channel == null) return@SnapshotCall
                    if (outcome is StampException) result.error(outcome.code, outcome.message, null) else result.success(outcome)
                }
                snapshots.add(call)
                MapSnapshot.run(ctx, activity, args, ex, call)
            }
            else -> result.notImplemented()
        }
    }

    private fun runInBackground(result: MethodChannel.Result, work: () -> Any?) {
        val ex = executor
        if (ex == null) { result.error("COMPOSITE", "plugin detached", null); return }
        ex.execute {
            val outcome: Any? = try {
                work()
            } catch (e: StampException) {
                e
            } catch (e: OutOfMemoryError) {
                StampException("OOM", e.toString())
            } catch (e: Throwable) {
                StampException("COMPOSITE", e.toString())
            }
            main.post {
                if (channel == null) return@post // the engine detached while the job ran: no reply to a dead messenger
                if (outcome is StampException) result.error(outcome.code, outcome.message, null) else result.success(outcome)
            }
        }
    }
}
