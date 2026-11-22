package com.community.flutter.stampcomposite

import kotlin.math.PI
import kotlin.math.cos
import kotlin.math.pow
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNull
import kotlin.test.assertTrue

/** The Android mini-map's pure parts: the zoom for a span, and which manifest values count as a key. */
internal class MapSnapshotMathTest {
    /** Metres the [widthDp] dp map covers at [zoom] (the inverse of zoomFor, from the Web Mercator definition). */
    private fun spanAt(lat: Double, zoom: Float, widthDp: Double) =
        widthDp * 40_075_016.686 / 256.0 * cos(lat * PI / 180) / 2.0.pow(zoom.toDouble())

    @Test
    fun zoomCoversTheRequestedSpan() {
        for (lat in listOf(0.0, 12.9716, 32.08, 51.5, -33.9, 64.1)) {
            for (span in listOf(100.0, 500.0, 2000.0)) {
                val z = MapSnapshotMath.zoomFor(lat, span, 160.0)
                assertEquals(span, spanAt(lat, z, 160.0), span * 1e-4, "lat=$lat span=$span z=$z")
            }
        }
    }

    @Test
    fun equator500mOn160dpIsAboutZoom15_6() {
        assertEquals(15.61, MapSnapshotMath.zoomFor(0.0, 500.0, 160.0).toDouble(), 0.01)
        // Twice the span = one zoom level out.
        assertEquals(1.0, (MapSnapshotMath.zoomFor(40.0, 500.0, 160.0) - MapSnapshotMath.zoomFor(40.0, 1000.0, 160.0)).toDouble(), 1e-4)
    }

    @Test
    fun zoomIsClampedToTheSdkRange() {
        assertEquals(21f, MapSnapshotMath.zoomFor(0.0, 0.5, 512.0))
        assertEquals(2f, MapSnapshotMath.zoomFor(0.0, 40_000_000.0, 32.0))
    }

    @Test
    fun theHostViewStaysInsideTheWindow() {
        assertEquals(480, MapSnapshotMath.viewPixels(160.0, 3.0, 1080, 2400))
        assertEquals(400, MapSnapshotMath.viewPixels(512.0, 4.0, 400, 900), "never larger than the window's short side")
        assertEquals(64, MapSnapshotMath.viewPixels(32.0, 1.0, 1080, 2400), "at least 64 px")
        assertEquals(480, MapSnapshotMath.viewPixels(160.0, 3.0, 0, 0), "a window not laid out yet: the requested size")
        assertTrue(MapSnapshotMath.HOST_ALPHA > 0f && MapSnapshotMath.HOST_ALPHA < 0.05f, "drawn, but invisible")
    }

    @Test
    fun onlyARealKeyIsUsable() {
        assertNull(MapSnapshotMath.usableKey(null))
        assertNull(MapSnapshotMath.usableKey(""))
        assertNull(MapSnapshotMath.usableKey("   "))
        assertNull(MapSnapshotMath.usableKey("\${mapsApiKey}"))
        assertEquals("AIzaSyExample", MapSnapshotMath.usableKey(" AIzaSyExample "))
    }
}
