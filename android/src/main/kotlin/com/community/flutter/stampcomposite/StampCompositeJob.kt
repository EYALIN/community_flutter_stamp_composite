package com.community.flutter.stampcomposite

import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.BitmapRegionDecoder
import android.graphics.Canvas
import android.graphics.Matrix
import android.graphics.Paint
import android.graphics.Rect
import android.os.Build
import android.os.SystemClock
import androidx.exifinterface.media.ExifInterface
import java.io.File
import java.io.FileOutputStream
import java.nio.ByteBuffer
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale
import java.util.TimeZone
import kotlin.math.max
import kotlin.math.min
import kotlin.math.roundToInt

/** A failure with a channel error code: NOT_FOUND, OOM or COMPOSITE. */
class StampException(val code: String, message: String) : Exception(message)

/**
 * One composite: decode the camera JPEG straight to the output size (never a full-size bitmap unless the
 * output IS the full size), apply EXIF orientation -> extraRotation -> mirror, draw the stamp overlay,
 * encode JPEG, write EXIF. Runs on the plugin's single background executor only.
 *
 * Decode ("auto" mode of the POC, measured in research/phase1/TECHNICAL-POC-RESULTS.md):
 *  - exact-sample: the output long edge is source / 2^k (k = 0..3) -> BitmapFactory inSampleSize = 2^k
 *    (libjpeg scaled IDCT) + one transform draw.
 *  - stripes: any other ratio -> BitmapRegionDecoder decodes horizontal stripes of the stored image at the
 *    largest power-of-two sample that stays >= the output size, each drawn transformed into the output.
 */
internal class StampCompositeJob(args: Map<*, *>) {
    private val src = args["src"] as String
    private val out = args["out"] as String
    private val outW = (args["outWidth"] as Number).toInt()
    private val outH = (args["outHeight"] as Number).toInt()
    private val mirror = args["mirror"] as? Boolean ?: false
    private val extraRotation = (args["extraRotation"] as? Number)?.toInt() ?: 0
    private val overlay = args["overlayRgba"] as? ByteArray
    private val overlayW = (args["overlayWidth"] as? Number)?.toInt() ?: 0
    private val overlayH = (args["overlayHeight"] as? Number)?.toInt() ?: 0
    private val overlayLeft = (args["overlayLeft"] as? Number)?.toInt() ?: 0
    private val overlayTop = (args["overlayTop"] as? Number)?.toInt() ?: 0
    private val quality = (args["quality"] as? Number)?.toInt() ?: 90
    private val exif = args["exif"] as? Map<*, *>
    private val stripeBytes = ((args["stripeMB"] as? Number)?.toInt() ?: 24) * 1_000_000

    /** Test hook: the first N attempts throw OutOfMemoryError (exercises the retry and the OOM code). */
    private var debugFailAttempts = (args["debugFailAttempts"] as? Number)?.toInt() ?: 0

    fun run(): Map<String, Any?> {
        if (!File(src).isFile) throw StampException("NOT_FOUND", "source not found: $src")
        if (outW <= 0 || outH <= 0) throw StampException("COMPOSITE", "bad output size ${outW}x$outH")
        if (overlay != null && overlay.size != overlayW * overlayH * 4) {
            throw StampException("COMPOSITE", "overlay is ${overlay.size} bytes, expected ${overlayW}x${overlayH}x4")
        }
        if (normalizedOrNull(extraRotation) == null) throw StampException("COMPOSITE", "extraRotation must be 0/90/180/270")
        val t0 = SystemClock.elapsedRealtimeNanos()
        return try {
            attempt(outW, outH, false, t0)
        } catch (first: OutOfMemoryError) {
            File(out).delete()
            System.gc()
            val (w2, h2) = StampTransform.outputSize(outW, outH, max(outW, outH) / 2, 0)
            try {
                attempt(w2, h2, true, t0)
            } catch (second: OutOfMemoryError) {
                File(out).delete()
                throw StampException("OOM", "out of memory at ${outW}x$outH and at ${w2}x$h2")
            }
        } catch (e: StampException) {
            File(out).delete(); throw e
        } catch (e: Exception) {
            File(out).delete(); throw StampException("COMPOSITE", e.toString())
        }
    }

    private fun normalizedOrNull(deg: Int) = try { StampTransform.normalizeRotation(deg) } catch (_: IllegalArgumentException) { null }

    private fun attempt(ow: Int, oh: Int, downscaled: Boolean, t0: Long): Map<String, Any?> {
        if (debugFailAttempts > 0) { debugFailAttempts--; throw OutOfMemoryError("debugFailAttempts") }
        val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
        BitmapFactory.decodeFile(src, bounds)
        val sw = bounds.outWidth; val sh = bounds.outHeight
        if (sw <= 0 || sh <= 0) throw StampException("COMPOSITE", "cannot decode $src")
        val orientation = ExifInterface(src).getAttributeInt(ExifInterface.TAG_ORIENTATION, ExifInterface.ORIENTATION_NORMAL)
        val transform = StampTransform.build(orientation, extraRotation, mirror, sw, sh, ow, oh)
        val sample = StampTransform.exactSampleFor(orientation, extraRotation, sw, sh, ow, oh)
        val paint = Paint(Paint.FILTER_BITMAP_FLAG)
        var outBmp: Bitmap? = null
        val mode: String
        val usedSample: Int
        try {
            if (sample > 0) {
                mode = "exact-sample"; usedSample = sample
                var decoded: Bitmap? = null
                try {
                    decoded = BitmapFactory.decodeFile(src, BitmapFactory.Options().apply {
                        inSampleSize = sample; inPreferredConfig = Bitmap.Config.ARGB_8888; inMutable = true
                    }) ?: throw StampException("COMPOSITE", "cannot decode $src")
                    val m = transform.preScale(sw.toDouble() / decoded.width, sh.toDouble() / decoded.height)
                    if (m == Affine.IDENTITY && decoded.width == ow && decoded.height == oh) {
                        outBmp = decoded; decoded = null // already upright at the output size: draw the stamp in place
                    } else {
                        outBmp = Bitmap.createBitmap(ow, oh, Bitmap.Config.ARGB_8888)
                        Canvas(outBmp).drawBitmap(decoded, matrix(m), paint)
                    }
                } finally {
                    decoded?.recycle()
                }
            } else {
                mode = "stripes"
                // only the stored rows / columns inside the cover crop are ever decoded
                val crop = StampTransform.coverCrop(orientation, extraRotation, sw, sh, ow, oh)
                val region = StampTransform.storedCropRect(orientation, sw, sh, crop)
                val scale = max(ow, oh).toDouble() / max(crop.width, crop.height) // upright crop px -> output px
                var s = 1
                while (scale * s * 2 <= 1.0) s *= 2 // never decode below the output size
                usedSample = s
                outBmp = Bitmap.createBitmap(ow, oh, Bitmap.Config.ARGB_8888)
                drawStripes(outBmp, transform, region, s, paint)
            }
            val t1 = SystemClock.elapsedRealtimeNanos()
            drawOverlay(outBmp, ow.toDouble() / outW, paint)
            val t2 = SystemClock.elapsedRealtimeNanos()
            val ok = FileOutputStream(out).use { outBmp.compress(Bitmap.CompressFormat.JPEG, quality.coerceIn(1, 100), it) }
            if (!ok) throw StampException("COMPOSITE", "JPEG encode failed")
            outBmp.recycle(); outBmp = null
            val t3 = SystemClock.elapsedRealtimeNanos()
            writeExif()
            val t4 = SystemClock.elapsedRealtimeNanos()
            return mapOf(
                "width" to ow, "height" to oh, "decodeMode" to mode, "inSampleSize" to usedSample,
                "decodeMs" to (t1 - t0) / 1e6, "drawMs" to (t2 - t1) / 1e6, "encodeMs" to (t3 - t2) / 1e6,
                "exifMs" to (t4 - t3) / 1e6, "totalMs" to (t4 - t0) / 1e6, "downscaledForMemory" to downscaled,
                "srcOrientation" to orientation,
            )
        } finally {
            outBmp?.recycle()
        }
    }

    private fun matrix(a: Affine) = Matrix().apply { setValues(a.toMatrixValues()) }

    /** [region] = stored (left, top, right, bottom) to decode; everything outside it is cropped away anyway. */
    private fun drawStripes(outBmp: Bitmap, transform: Affine, region: IntArray, sample: Int, paint: Paint) {
        val (x0, y0, x1, y1end) = region
        val sw = x1 - x0
        val c = Canvas(outBmp)
        @Suppress("DEPRECATION")
        val rd = (if (Build.VERSION.SDK_INT >= 31) BitmapRegionDecoder.newInstance(src) else BitmapRegionDecoder.newInstance(src, false))
            ?: throw StampException("COMPOSITE", "cannot open a region decoder for $src")
        var reuse: Bitmap? = null
        try {
            val opts = BitmapFactory.Options().apply { inSampleSize = sample; inPreferredConfig = Bitmap.Config.ARGB_8888 }
            val stripe = max(256, stripeBytes / max(1, sw / sample) / 4) * sample // stored rows per stripe
            val margin = 2 * sample // overlap so bilinear filtering has neighbours at the seams
            val srcH = rd.height; val srcW = rd.width
            // horizontal margin too, so filtering at the crop's left / right edge has neighbours
            val left = max(0, x0 - margin); val right = min(srcW, x1 + margin)
            var y = y0
            while (y < y1end) {
                val y1 = min(y1end, y + stripe)
                val top = max(0, y - margin); val bot = min(srcH, y1 + margin)
                opts.inBitmap = reuse; opts.inMutable = true
                val b = try {
                    rd.decodeRegion(Rect(left, top, right, bot), opts)
                } catch (e: IllegalArgumentException) { // inBitmap not reusable for this (last, shorter) stripe
                    opts.inBitmap = null; reuse?.recycle(); reuse = null
                    rd.decodeRegion(Rect(left, top, right, bot), opts)
                } ?: throw StampException("COMPOSITE", "region decode failed at row $top")
                if (b !== reuse) reuse?.recycle()
                reuse = b
                // clip to this stripe's own rows (mapped to output) so the overlaps don't double-draw
                val r = transform.mapRect(x0.toDouble(), y.toDouble(), x1.toDouble(), y1.toDouble())
                c.save()
                c.clipRect(r[0].toFloat(), r[1].toFloat(), r[2].toFloat(), r[3].toFloat())
                val m = transform.preTranslate(left.toDouble(), top.toDouble())
                    .preScale(sample.toDouble(), sample.toDouble())
                c.drawBitmap(b, matrix(m), paint)
                c.restore()
                y = y1
            }
        } finally {
            reuse?.recycle()
            rd.recycle()
        }
    }

    /** The stamp (premultiplied RGBA from dart:ui) at (overlayLeft, overlayTop); [f] < 1 only on the OOM retry. */
    private fun drawOverlay(outBmp: Bitmap, f: Double, paint: Paint) {
        val bytes = overlay ?: return
        if (overlayW <= 0 || overlayH <= 0) return
        var ov: Bitmap? = null
        try {
            ov = Bitmap.createBitmap(overlayW, overlayH, Bitmap.Config.ARGB_8888)
            ov.copyPixelsFromBuffer(ByteBuffer.wrap(bytes))
            val m = Affine(f, 0.0, 0.0, f, overlayLeft * f, overlayTop * f)
            Canvas(outBmp).drawBitmap(ov, matrix(m), if (f == 1.0) null else paint)
        } finally {
            ov?.recycle()
        }
    }

    private fun writeExif() {
        val e = ExifInterface(out)
        e.setAttribute(ExifInterface.TAG_ORIENTATION, ExifInterface.ORIENTATION_NORMAL.toString())
        val x = exif
        if (x == null) {
            // Bitmap.compress copies no metadata; clear GPS anyway so a stale tag can never leak a location
            for (t in GPS_TAGS) e.setAttribute(t, null)
            e.saveAttributes()
            return
        }
        fun str(k: String) = x[k] as? String
        fun num(k: String) = (x[k] as? Number)?.toDouble()
        str("capturedLocal")?.let {
            e.setAttribute(ExifInterface.TAG_DATETIME_ORIGINAL, it)
            e.setAttribute(ExifInterface.TAG_DATETIME, it)
            e.setAttribute(ExifInterface.TAG_DATETIME_DIGITIZED, it)
        }
        str("utcOffset")?.let {
            e.setAttribute(ExifInterface.TAG_OFFSET_TIME_ORIGINAL, it)
            e.setAttribute(ExifInterface.TAG_OFFSET_TIME, it)
            e.setAttribute(ExifInterface.TAG_OFFSET_TIME_DIGITIZED, it)
        }
        val lat = num("lat"); val lon = num("lon")
        if (lat != null && lon != null) e.setLatLong(lat, lon)
        num("altitude")?.let { e.setAltitude(it) }
        num("accuracyMeters")?.let {
            e.setAttribute(ExifInterface.TAG_GPS_H_POSITIONING_ERROR, "${(it * 1000).roundToInt()}/1000")
        }
        (x["gpsUtcMillis"] as? Number)?.toLong()?.let { ms ->
            val d = Date(ms)
            e.setAttribute(ExifInterface.TAG_GPS_DATESTAMP, utc("yyyy:MM:dd").format(d))
            e.setAttribute(ExifInterface.TAG_GPS_TIMESTAMP, utc("HH:mm:ss").format(d))
        }
        str("make")?.let { e.setAttribute(ExifInterface.TAG_MAKE, it) }
        str("model")?.let { e.setAttribute(ExifInterface.TAG_MODEL, it) }
        str("software")?.let { e.setAttribute(ExifInterface.TAG_SOFTWARE, it) }
        str("userComment")?.let { e.setAttribute(ExifInterface.TAG_USER_COMMENT, it) }
        e.saveAttributes()
    }

    companion object {
        private fun utc(pattern: String) = SimpleDateFormat(pattern, Locale.US).apply { timeZone = TimeZone.getTimeZone("UTC") }

        private val GPS_TAGS = listOf(
            ExifInterface.TAG_GPS_LATITUDE, ExifInterface.TAG_GPS_LATITUDE_REF,
            ExifInterface.TAG_GPS_LONGITUDE, ExifInterface.TAG_GPS_LONGITUDE_REF,
            ExifInterface.TAG_GPS_ALTITUDE, ExifInterface.TAG_GPS_ALTITUDE_REF,
            ExifInterface.TAG_GPS_H_POSITIONING_ERROR, ExifInterface.TAG_GPS_DATESTAMP, ExifInterface.TAG_GPS_TIMESTAMP,
        )

        /** {width, height} after EXIF orientation, plus the stored size and the orientation tag. */
        fun orientedSize(path: String): Map<String, Any> {
            if (!File(path).isFile) throw StampException("NOT_FOUND", "source not found: $path")
            val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
            BitmapFactory.decodeFile(path, bounds)
            if (bounds.outWidth <= 0 || bounds.outHeight <= 0) throw StampException("COMPOSITE", "cannot decode $path")
            val o = ExifInterface(path).getAttributeInt(ExifInterface.TAG_ORIENTATION, ExifInterface.ORIENTATION_NORMAL)
            val (w, h) = StampTransform.orientedSize(o, bounds.outWidth, bounds.outHeight)
            return mapOf("width" to w, "height" to h, "orientation" to o,
                "storedWidth" to bounds.outWidth, "storedHeight" to bounds.outHeight)
        }
    }
}
