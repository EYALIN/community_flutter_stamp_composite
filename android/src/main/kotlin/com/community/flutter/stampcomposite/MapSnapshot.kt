package com.community.flutter.stampcomposite

import android.app.Activity
import android.content.Context
import android.content.pm.PackageManager
import android.graphics.Bitmap
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.Paint
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.view.View
import android.view.ViewGroup
import android.widget.FrameLayout
import com.google.android.gms.maps.GoogleMap
import com.google.android.gms.maps.GoogleMapOptions
import com.google.android.gms.maps.MapView
import com.google.android.gms.maps.MapsInitializer
import com.google.android.gms.maps.model.BitmapDescriptorFactory
import com.google.android.gms.maps.model.CameraPosition
import com.google.android.gms.maps.model.LatLng
import com.google.android.gms.maps.model.MapStyleOptions
import com.google.android.gms.maps.model.MarkerOptions
import java.io.ByteArrayOutputStream
import java.util.concurrent.Executor
import kotlin.math.PI
import kotlin.math.cos
import kotlin.math.ln
import kotlin.math.max
import kotlin.math.min
import kotlin.math.roundToInt

/**
 * The stamp's mini-map on Android: one Google Maps SDK for Android LITE-MODE map of a
 * square region around a position, with a pin at the centre, captured with [GoogleMap.snapshot] and encoded as PNG.
 *
 * - Key: the app's manifest meta-data `com.google.android.geo.API_KEY` (the Maps SDK reads the same entry). No key
 *   (or an empty one) = [isAvailable] false: nothing is requested and the stamp stays text only.
 * - Attribution: the lite map keeps its Google logo; no padding pushes it out of the frame and nothing is drawn over
 *   it (Google Maps Platform Terms: the logo must stay visible). Only the pin is drawn, at the centre.
 * - Cost: the mobile Maps SDK (lite mode included) has no per-load charge.
 * - A 10 s timeout, like the Dart cache's: a map that never loads (offline, refused key) fails, the view is torn down.
 */
internal object MapSnapshot {
    const val API_KEY_META = "com.google.android.geo.API_KEY"
    const val TIMEOUT_MS = 10_000L

    /** The manifest key, or null when it is missing / blank / an unexpanded placeholder. */
    fun apiKey(context: Context): String? = try {
        val pm = context.packageManager
        val info = if (Build.VERSION.SDK_INT >= 33) {
            pm.getApplicationInfo(context.packageName, PackageManager.ApplicationInfoFlags.of(PackageManager.GET_META_DATA.toLong()))
        } else {
            @Suppress("DEPRECATION") pm.getApplicationInfo(context.packageName, PackageManager.GET_META_DATA)
        }
        MapSnapshotMath.usableKey(info.metaData?.getString(API_KEY_META))
    } catch (e: Exception) {
        null
    }

    fun isAvailable(context: Context): Boolean = apiKey(context) != null

    /**
     * Arguments: `lat`, `lon` (required), `size` (square side in points, default 160), `scale` (default 3),
     * `spanMeters` (default 500), `dark`. Runs on the MAIN thread (MapView). [call] replies at most once, on the main
     * thread, with PNG bytes or a [StampException]; the plugin cancels it on a detach ([SnapshotCall.cancel]), which
     * tears the view down and drops every later callback. The PNG encode runs on [encoder].
     */
    fun run(context: Context, activity: Activity?, args: Map<*, *>, encoder: Executor, call: SnapshotCall) {
        val lat = (args["lat"] as? Number)?.toDouble()
        val lon = (args["lon"] as? Number)?.toDouble()
        if (lat == null || lon == null || lat !in -90.0..90.0 || lon !in -180.0..180.0) {
            call.finish(StampException("COMPOSITE", "lat and lon are required")); return
        }
        if (!isAvailable(context)) { call.finish(StampException("UNAVAILABLE", "no Maps API key in the manifest")); return }
        val host = activity?.window?.decorView as? ViewGroup
        if (host == null) { call.finish(StampException("COMPOSITE", "no activity to draw the map in")); return }
        val side = ((args["size"] as? Number)?.toDouble() ?: 160.0).coerceIn(32.0, 512.0)
        val scale = ((args["scale"] as? Number)?.toDouble() ?: 3.0).coerceIn(1.0, 4.0)
        val span = ((args["spanMeters"] as? Number)?.toDouble() ?: 500.0).coerceIn(50.0, 50_000.0)
        val dark = args["dark"] as? Boolean ?: false
        val px = MapSnapshotMath.viewPixels(side, scale, host.width, host.height)
        val density = context.resources.displayMetrics.density
        val zoom = MapSnapshotMath.zoomFor(lat, span, px / density.toDouble())
        val centre = LatLng(lat, lon)

        val main = Handler(Looper.getMainLooper())
        call.onTeardown { main.removeCallbacksAndMessages(null) }

        try {
            MapsInitializer.initialize(context.applicationContext)
            val options = GoogleMapOptions()
                .liteMode(true)
                .mapType(GoogleMap.MAP_TYPE_NORMAL)
                .mapToolbarEnabled(false)
                .compassEnabled(false)
                .camera(CameraPosition.fromLatLngZoom(centre, zoom))
            val v = MapView(activity, options)
            call.onTeardown {
                try {
                    v.onPause(); v.onStop(); v.onDestroy()
                } catch (_: Throwable) {}
                (v.parent as? ViewGroup)?.removeView(v)
            }
            v.onCreate(null)
            v.onStart()
            v.onResume()
            // Lite mode only draws inside a real window: the view is attached to the activity's decor view, size-limited
            // to the snapshot square at the top-left INSIDE the window, at index 0 (under the Flutter content, which is
            // opaque and draws over it) and almost transparent - on screen nothing changes, but the map lays out, loads
            // and draws. GoogleMap.snapshot() renders the map itself, whatever the view's alpha.
            v.alpha = MapSnapshotMath.HOST_ALPHA
            v.importantForAccessibility = View.IMPORTANT_FOR_ACCESSIBILITY_NO_HIDE_DESCENDANTS
            v.isClickable = false
            host.addView(v, 0, FrameLayout.LayoutParams(px, px))
            main.postDelayed({ call.finish(StampException("COMPOSITE", "map snapshot timed out")) }, TIMEOUT_MS)
            v.getMapAsync { map ->
                if (call.isDone) return@getMapAsync
                try {
                    if (dark) map.setMapStyle(MapStyleOptions(NIGHT_STYLE))
                    val r = (max(5.0, side * 0.045) * px / side).toFloat()
                    map.addMarker(
                        MarkerOptions().position(centre).anchor(0.5f, 0.5f).flat(true)
                            .icon(BitmapDescriptorFactory.fromBitmap(pin(r))),
                    )
                    map.setOnMapLoadedCallback {
                        if (call.isDone) return@setOnMapLoadedCallback
                        map.snapshot { bmp ->
                            if (call.isDone) return@snapshot
                            if (bmp == null) { call.finish(StampException("COMPOSITE", "snapshot returned no image")); return@snapshot }
                            encoder.execute {
                                val out: Any = try {
                                    ByteArrayOutputStream().use { s -> bmp.compress(Bitmap.CompressFormat.PNG, 100, s); s.toByteArray() }
                                } catch (e: Throwable) {
                                    StampException("COMPOSITE", "png encode failed: $e")
                                }
                                main.post { call.finish(out) }
                            }
                        }
                    }
                } catch (e: Throwable) {
                    call.finish(StampException("COMPOSITE", "map failed: $e"))
                }
            }
        } catch (e: Throwable) {
            call.finish(StampException("COMPOSITE", "map failed: $e"))
        }
    }

    /** A blue dot with a white ring and a soft shadow (#0743EE), the same pin as the iOS MapKit path. */
    private fun pin(r: Float): Bitmap {
        val pad = r * 0.6f
        val d = ((r + pad) * 2).roundToInt()
        val bmp = Bitmap.createBitmap(d, d, Bitmap.Config.ARGB_8888)
        val c = Canvas(bmp)
        val cx = d / 2f
        val ring = Paint(Paint.ANTI_ALIAS_FLAG).apply {
            color = Color.WHITE
            setShadowLayer(r * 0.6f, 0f, r * 0.15f, Color.argb(89, 0, 0, 0))
        }
        c.drawCircle(cx, cx, r, ring)
        c.drawCircle(cx, cx, r * 0.68f, Paint(Paint.ANTI_ALIAS_FLAG).apply { color = Color.rgb(0x07, 0x43, 0xEE) })
        return bmp
    }

    /** A plain dark map style for the dark stamp (roads, water and labels dimmed; nothing hidden). */
    private const val NIGHT_STYLE = """[
      {"elementType":"geometry","stylers":[{"color":"#242f3e"}]},
      {"elementType":"labels.text.stroke","stylers":[{"color":"#242f3e"}]},
      {"elementType":"labels.text.fill","stylers":[{"color":"#a4aab4"}]},
      {"featureType":"road","elementType":"geometry","stylers":[{"color":"#38414e"}]},
      {"featureType":"water","elementType":"geometry","stylers":[{"color":"#17263c"}]}
    ]"""
}

/** The pure parts of [MapSnapshot] (JVM unit-tested). */
internal object MapSnapshotMath {
    /** Metres per dp at zoom 0 on the equator (the world is 256 dp wide at zoom 0). */
    private const val EQUATOR_M_PER_DP_Z0 = 40_075_016.686 / 256.0

    /** The zoom at which [widthDp] dp of map at [latitude] cover [spanMeters], clamped to the SDK's 2..21. */
    fun zoomFor(latitude: Double, spanMeters: Double, widthDp: Double): Float {
        val metersPerDp = spanMeters / max(1.0, widthDp)
        val z = ln(EQUATOR_M_PER_DP_Z0 * cos(latitude * PI / 180) / metersPerDp) / ln(2.0)
        return min(21.0, max(2.0, z)).toFloat()
    }

    /** The off-screen host view's alpha: drawn (lite mode needs a real draw), but invisible under the Flutter view. */
    const val HOST_ALPHA = 0.01f

    /**
     * The map view's square side in pixels: the requested `side * scale`, but never larger than the window it is
     * attached to (a view outside the window is not drawn, and lite mode then never loads), and at least 64 px.
     */
    fun viewPixels(side: Double, scale: Double, hostWidth: Int, hostHeight: Int): Int {
        val want = (side * scale).roundToInt()
        val room = if (hostWidth > 0 && hostHeight > 0) min(hostWidth, hostHeight) else want
        return max(64, min(want, room))
    }

    /** A manifest value that is a real key: not null, not blank, not an unexpanded `${placeholder}`. */
    fun usableKey(raw: String?): String? = raw?.trim()?.takeIf { it.isNotEmpty() && !it.startsWith("\${") }
}
