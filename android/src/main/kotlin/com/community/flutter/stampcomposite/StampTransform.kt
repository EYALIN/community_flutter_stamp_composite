package com.community.flutter.stampcomposite

import kotlin.math.ceil
import kotlin.math.floor
import kotlin.math.max
import kotlin.math.min
import kotlin.math.roundToLong

/**
 * A 2-D affine map in image coordinates (origin top-left, y down):
 * `x' = a*x + b*y + tx`, `y' = c*x + d*y + ty`.
 *
 * Pure Kotlin (no android.* types) so the orientation math runs in plain JVM unit tests. The same type
 * and the same functions exist in Swift (`StampTransform.swift`) and Dart (`lib/src/geometry.dart`).
 */
data class Affine(
    val a: Double, val b: Double, val c: Double, val d: Double, val tx: Double, val ty: Double,
) {
    fun mapX(x: Double, y: Double) = a * x + b * y + tx
    fun mapY(x: Double, y: Double) = c * x + d * y + ty

    /** `this` first, then [next]. */
    fun then(next: Affine) = Affine(
        a = next.a * a + next.b * c,
        b = next.a * b + next.b * d,
        c = next.c * a + next.d * c,
        d = next.c * b + next.d * d,
        tx = next.a * tx + next.b * ty + next.tx,
        ty = next.c * tx + next.d * ty + next.ty,
    )

    /** Scale the INPUT by ([sx], [sy]) before this map (e.g. a bitmap decoded at 1/sample). */
    fun preScale(sx: Double, sy: Double) = Affine(a * sx, b * sy, c * sx, d * sy, tx, ty)

    /** Translate the INPUT by ([dx], [dy]) before this map (e.g. a stripe that starts at row dy). */
    fun preTranslate(dx: Double, dy: Double) = Affine(a, b, c, d, tx + a * dx + b * dy, ty + c * dx + d * dy)

    /** Axis-aligned bounds of the mapped rectangle (exact for the 90° multiples used here). */
    fun mapRect(l: Double, t: Double, r: Double, btm: Double): DoubleArray {
        val xs = doubleArrayOf(mapX(l, t), mapX(r, t), mapX(l, btm), mapX(r, btm))
        val ys = doubleArrayOf(mapY(l, t), mapY(r, t), mapY(l, btm), mapY(r, btm))
        return doubleArrayOf(xs.min(), ys.min(), xs.max(), ys.max())
    }

    fun inverse(): Affine {
        val det = a * d - b * c
        require(det != 0.0) { "singular transform" }
        val ia = d / det; val ib = -b / det; val ic = -c / det; val id = a / det
        return Affine(ia, ib, ic, id, -(ia * tx + ib * ty), -(ic * tx + id * ty))
    }

    /** The 3x3 row-major values android.graphics.Matrix.setValues expects. */
    fun toMatrixValues() = floatArrayOf(
        a.toFloat(), b.toFloat(), tx.toFloat(),
        c.toFloat(), d.toFloat(), ty.toFloat(),
        0f, 0f, 1f,
    )

    companion object {
        val IDENTITY = Affine(1.0, 0.0, 0.0, 1.0, 0.0, 0.0)
    }
}

/**
 * Final transform = EXIF orientation, then [extraRotation] clockwise, then [mirror] (horizontal flip),
 * then scale to the output size. Maps STORED source pixel coordinates to OUTPUT pixel coordinates.
 */
object StampTransform {
    /** EXIF 5..8 store the image transposed: the upright image is h x w. */
    fun swapsAxes(exifOrientation: Int) = exifOrientation in 5..8

    fun orientedSize(exifOrientation: Int, w: Int, h: Int): Pair<Int, Int> =
        if (swapsAxes(exifOrientation)) h to w else w to h

    /**
     * The output-size rule (identical to the Dart `outputSize`; native never re-derives it for a normal call —
     * Dart passes outW/outH — it is used only for the OOM retry at half the cap):
     * long edge <= cap -> unchanged; else long edge = cap, short edge = round(short * cap / long) (>= 1).
     * A long edge of cap * 2^k gives exactly source / 2^k. 90 / 270 swap width and height.
     */
    fun outputSize(srcOrientedW: Int, srcOrientedH: Int, maxLongEdge: Int, extraRotation: Int): Pair<Int, Int> {
        require(srcOrientedW > 0 && srcOrientedH > 0) { "empty source" }
        require(maxLongEdge > 0) { "maxLongEdge must be > 0" }
        val long = max(srcOrientedW, srcOrientedH)
        var w = srcOrientedW
        var h = srcOrientedH
        if (long > maxLongEdge) {
            val s = maxLongEdge.toDouble() / long
            if (srcOrientedW >= srcOrientedH) {
                w = maxLongEdge; h = max(1L, roundHalfUp(srcOrientedH * s)).toInt()
            } else {
                h = maxLongEdge; w = max(1L, roundHalfUp(srcOrientedW * s)).toInt()
            }
        }
        return if (normalizeRotation(extraRotation) % 180 == 90) h to w else w to h
    }

    /** Dart's double.round() rounds half away from zero; Kotlin's roundToLong rounds half up — same for x >= 0. */
    private fun roundHalfUp(x: Double) = x.roundToLong()

    fun normalizeRotation(deg: Int): Int {
        require(deg % 90 == 0) { "extraRotation must be a multiple of 90, got $deg" }
        return ((deg % 360) + 360) % 360
    }

    /**
     * The decode sample when the output long edge is exactly source long edge / 2^k (k = 0..3), else 0.
     * Such outputs decode with BitmapFactory inSampleSize (libjpeg scaled IDCT); every other ratio uses stripes.
     */
    fun exactSample(srcLong: Int, outLong: Int): Int {
        var k = 1
        while (k <= 8) {
            if (srcLong == outLong * k) return k
            k *= 2
        }
        return 0
    }

    /** Stored w x h -> upright box (EXIF orientation 1..8; anything else = 1). */
    fun exifStep(o: Int, w: Double, h: Double): Affine = when (o) {
        2 -> Affine(-1.0, 0.0, 0.0, 1.0, w, 0.0)          // flip horizontal
        3 -> Affine(-1.0, 0.0, 0.0, -1.0, w, h)           // rotate 180
        4 -> Affine(1.0, 0.0, 0.0, -1.0, 0.0, h)          // flip vertical
        5 -> Affine(0.0, 1.0, 1.0, 0.0, 0.0, 0.0)         // transpose
        6 -> Affine(0.0, -1.0, 1.0, 0.0, h, 0.0)          // rotate 90 CW
        7 -> Affine(0.0, -1.0, -1.0, 0.0, h, w)           // transverse
        8 -> Affine(0.0, 1.0, -1.0, 0.0, 0.0, w)          // rotate 270 CW
        else -> Affine.IDENTITY
    }

    /** Clockwise rotation of a w x h box by [deg] (0/90/180/270), result again at the origin. */
    fun rotationStep(deg: Int, w: Double, h: Double): Affine = when (normalizeRotation(deg)) {
        90 -> Affine(0.0, -1.0, 1.0, 0.0, h, 0.0)
        180 -> Affine(-1.0, 0.0, 0.0, -1.0, w, h)
        270 -> Affine(0.0, 1.0, -1.0, 0.0, 0.0, w)
        else -> Affine.IDENTITY
    }

    /** Output dimensions before scaling: stored size after EXIF orientation and the extra rotation. */
    fun rotatedSize(exifOrientation: Int, extraRotation: Int, srcW: Int, srcH: Int): Pair<Int, Int> {
        val (uw, uh) = orientedSize(exifOrientation, srcW, srcH)
        return if (normalizeRotation(extraRotation) % 180 == 90) uh to uw else uw to uh
    }

    /** The centred crop of the upright source, in upright pixels: (left, top, width, height). */
    data class Crop(val left: Double, val top: Double, val width: Double, val height: Double)

    /**
     * Cover + centre-crop: when the output ratio (rotated back to the upright orientation) differs from the
     * upright source's, the source is scaled to COVER the output and the excess on the long side is cropped equally
     * from both ends — never stretched. Same rule as Flutter's applyBoxFit(BoxFit.cover) + Alignment.center used by
     * the Dart fallback compositor. Equal ratios give the whole source.
     */
    fun coverCrop(exifOrientation: Int, extraRotation: Int, srcW: Int, srcH: Int, outW: Int, outH: Int): Crop {
        val (uw, uh) = orientedSize(exifOrientation, srcW, srcH)
        val rotated = normalizeRotation(extraRotation) % 180 == 90
        val dw = (if (rotated) outH else outW).toDouble()
        val dh = (if (rotated) outW else outH).toDouble()
        return if (dw / dh > uw.toDouble() / uh) {
            val ch = uw * dh / dw
            Crop(0.0, (uh - ch) / 2, uw.toDouble(), ch)
        } else {
            val cw = uh * dw / dh
            Crop((uw - cw) / 2, 0.0, cw, uh.toDouble())
        }
    }

    /**
     * Stored source pixel coordinates -> output pixel coordinates (outW x outH):
     * EXIF orientation -> centre crop (cover) -> extraRotation -> scale -> mirror.
     */
    fun build(exifOrientation: Int, extraRotation: Int, mirror: Boolean, srcW: Int, srcH: Int, outW: Int, outH: Int): Affine {
        val crop = coverCrop(exifOrientation, extraRotation, srcW, srcH, outW, outH)
        val rotated = normalizeRotation(extraRotation) % 180 == 90
        val rw = if (rotated) crop.height else crop.width
        val rh = if (rotated) crop.width else crop.height
        var m = exifStep(exifOrientation, srcW.toDouble(), srcH.toDouble())
        m = m.then(Affine(1.0, 0.0, 0.0, 1.0, -crop.left, -crop.top))
        m = m.then(rotationStep(extraRotation, crop.width, crop.height))
        m = m.then(Affine(outW / rw, 0.0, 0.0, outH / rh, 0.0, 0.0))
        if (mirror) m = m.then(Affine(-1.0, 0.0, 0.0, 1.0, outW.toDouble(), 0.0))
        return m
    }

    /** The stored-pixel rectangle the crop covers: (left, top, right, bottom), whole pixels, clamped. */
    fun storedCropRect(exifOrientation: Int, srcW: Int, srcH: Int, crop: Crop): IntArray {
        val inv = exifStep(exifOrientation, srcW.toDouble(), srcH.toDouble()).inverse()
        val r = inv.mapRect(crop.left, crop.top, crop.left + crop.width, crop.top + crop.height)
        val eps = 1e-6
        return intArrayOf(
            clamp(floor(r[0] + eps).toInt(), 0, srcW), clamp(floor(r[1] + eps).toInt(), 0, srcH),
            clamp(ceil(r[2] - eps).toInt(), 0, srcW), clamp(ceil(r[3] - eps).toInt(), 0, srcH),
        )
    }

    /**
     * The BitmapFactory inSampleSize for the exact-sample decode path, or 0 = use stripes. Exact-sample is valid only
     * when the output is the whole source / 2^k: the long edges match AND the cover crop trims less than one sampled
     * pixel per axis (otherwise a cropped output would decode — and hold — the whole source).
     */
    fun exactSampleFor(exifOrientation: Int, extraRotation: Int, srcW: Int, srcH: Int, outW: Int, outH: Int): Int {
        val k = exactSample(max(srcW, srcH), max(outW, outH))
        if (k == 0) return 0
        val (uw, uh) = orientedSize(exifOrientation, srcW, srcH)
        val c = coverCrop(exifOrientation, extraRotation, srcW, srcH, outW, outH)
        return if (uw - c.width < k && uh - c.height < k) k else 0
    }

    /** Clamp helper for stripe rows. */
    internal fun clamp(v: Int, lo: Int, hi: Int) = min(hi, max(lo, v))
}
