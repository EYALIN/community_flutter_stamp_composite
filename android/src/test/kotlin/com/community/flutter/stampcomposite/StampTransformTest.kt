package com.community.flutter.stampcomposite

import kotlin.math.floor
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith

/**
 * The transform is checked against an INDEPENDENT model: the EXIF orientations, the extra rotation and the
 * mirror are re-built from two array primitives (rotate 90° clockwise, flip horizontal) applied to a labelled
 * grid, and every stored pixel centre mapped through [StampTransform.build] must land on its own label.
 */
internal class StampTransformTest {
    private class Grid(val w: Int, val h: Int, val px: IntArray) {
        operator fun get(x: Int, y: Int) = px[y * w + x]
        fun rot90cw(): Grid { // new (h x w): new[r][c] = old[h-1-c][r]
            val nw = h; val nh = w
            return Grid(nw, nh, IntArray(nw * nh) { i -> val c = i % nw; val r = i / nw; this[r, h - 1 - c] })
        }
        fun flipH() = Grid(w, h, IntArray(w * h) { i -> val c = i % w; val r = i / w; this[w - 1 - c, r] })
        fun rot(n: Int): Grid { var g = this; repeat(n) { g = g.rot90cw() }; return g }
    }

    /** EXIF 1..8 from the two primitives only (TIFF 6.0 / EXIF 2.32 definitions). */
    private fun orient(g: Grid, o: Int): Grid = when (o) {
        1 -> g
        2 -> g.flipH()
        3 -> g.rot(2)
        4 -> g.rot(2).flipH()          // flip vertical
        5 -> g.flipH().rot(3)          // transpose = mirror + rotate 270 CW
        6 -> g.rot(1)
        7 -> g.flipH().rot(1)          // transverse = mirror + rotate 90 CW
        8 -> g.rot(3)
        else -> error("o=$o")
    }

    private fun labelled(w: Int, h: Int) = Grid(w, h, IntArray(w * h) { it })

    @Test
    fun allOrientationsRotationsAndMirror_mapEveryPixelOntoTheModel() {
        val w = 5; val h = 3
        val src = labelled(w, h)
        for (o in 1..8) for (rot in listOf(0, 90, 180, 270)) for (mirror in listOf(false, true)) {
            var model = orient(src, o).rot(rot / 90)
            if (mirror) model = model.flipH()
            val (rw, rh) = StampTransform.rotatedSize(o, rot, w, h)
            assertEquals(model.w to model.h, rw to rh, "dims o=$o rot=$rot mirror=$mirror")
            val t = StampTransform.build(o, rot, mirror, w, h, rw, rh)
            for (y in 0 until h) for (x in 0 until w) {
                val X = floor(t.mapX(x + 0.5, y + 0.5)).toInt()
                val Y = floor(t.mapY(x + 0.5, y + 0.5)).toInt()
                assertEquals(src[x, y], model[X, Y], "o=$o rot=$rot mirror=$mirror pixel ($x,$y) -> ($X,$Y)")
            }
            // scaled output: the four stored corners land on the four output corners in the model's order
            val ow = rw * 4; val oh = rh * 4
            val s = StampTransform.build(o, rot, mirror, w, h, ow, oh)
            val corners = listOf(0.0 to 0.0, w.toDouble() to 0.0, 0.0 to h.toDouble(), w.toDouble() to h.toDouble())
            for ((cx, cy) in corners) {
                val X = s.mapX(cx, cy); val Y = s.mapY(cx, cy)
                assert((X == 0.0 || X == ow.toDouble()) && (Y == 0.0 || Y == oh.toDouble())) { "corner o=$o rot=$rot -> ($X,$Y)" }
            }
        }
    }

    /** Centre crop of the model grid (the cover crop of a 6x4 / 4x6 upright into a square is 1 pixel per side). */
    private fun Grid.cropSquare(): Grid {
        val n = minOf(w, h); val ox = (w - n) / 2; val oy = (h - n) / 2
        return Grid(n, n, IntArray(n * n) { i -> this[ox + i % n, oy + i / n] })
    }

    @Test
    fun coverCrop_allOrientationsRotationsAndMirror_squareOutputFromNonSquareSource() {
        val w = 6; val h = 4
        val src = labelled(w, h)
        for (o in 1..8) for (rot in listOf(0, 90, 180, 270)) for (mirror in listOf(false, true)) {
            var model = orient(src, o).cropSquare().rot(rot / 90)
            if (mirror) model = model.flipH()
            val t = StampTransform.build(o, rot, mirror, w, h, 4, 4)
            var inside = 0
            for (y in 0 until h) for (x in 0 until w) {
                val fx = t.mapX(x + 0.5, y + 0.5); val fy = t.mapY(x + 0.5, y + 0.5)
                if (fx < 0 || fy < 0 || fx >= 4 || fy >= 4) continue // cropped away
                inside++
                assertEquals(src[x, y], model[floor(fx).toInt(), floor(fy).toInt()], "crop o=$o rot=$rot mirror=$mirror ($x,$y)")
            }
            assertEquals(16, inside, "16 of 24 pixels survive the crop (o=$o rot=$rot)")
            // the stored rectangle to decode is exactly the 4x4 the crop keeps
            val crop = StampTransform.coverCrop(o, rot, w, h, 4, 4)
            val r = StampTransform.storedCropRect(o, w, h, crop)
            // (upright 6x4 keeps columns 1..5; upright 4x6 keeps rows 1..5 = stored columns 1..5; flips are symmetric)
            assertEquals(listOf(1, 0, 5, 4), r.toList(), "stored crop o=$o")
        }
    }

    @Test
    fun coverCrop_16x9OutputFrom4x3_keepsASquareSquare() {
        // 4000x3000 orientation 1, output 2250x4000 with extraRotation 90: upright crop 4000x2250 centred (top 375)
        val crop = StampTransform.coverCrop(1, 90, 4000, 3000, 2250, 4000)
        assertEquals(StampTransform.Crop(0.0, 375.0, 4000.0, 2250.0), crop)
        val t = StampTransform.build(1, 90, false, 4000, 3000, 2250, 4000)
        val r = t.mapRect(1800.0, 1300.0, 2200.0, 1700.0) // centred 400 px square
        assertEquals(400.0, r[2] - r[0], 1e-9); assertEquals(400.0, r[3] - r[1], 1e-9)
        assertEquals(listOf(0, 375, 4000, 2625), StampTransform.storedCropRect(1, 4000, 3000, crop).toList())
        assertEquals(0, StampTransform.exactSampleFor(1, 90, 4000, 3000, 2250, 4000), "a crop must not take the exact-sample path")
        assertEquals(1, StampTransform.exactSampleFor(1, 90, 4000, 3000, 3000, 4000))
        assertEquals(2, StampTransform.exactSampleFor(6, 0, 8000, 6000, 3000, 4000))
    }

    @Test
    fun upsideDownPortraitFix_rotation180_putsStoredBottomRightAtTopLeft() {
        val t = StampTransform.build(1, 180, false, 3000, 4000, 3000, 4000)
        assertEquals(0.0, t.mapX(3000.0, 4000.0)); assertEquals(0.0, t.mapY(3000.0, 4000.0))
    }

    @Test
    fun mirror_flipsHorizontallyAfterRotation() {
        // orientation 6 (stored landscape, upright portrait), no extra rotation, mirrored:
        // stored top-left goes to upright top-right, mirrored back to top-left.
        val t = StampTransform.build(6, 0, true, 4000, 3000, 3000, 4000)
        assertEquals(0.0, t.mapX(0.0, 0.0)); assertEquals(0.0, t.mapY(0.0, 0.0))
    }

    @Test
    fun outputSize_rule() {
        assertEquals(4000 to 3000, StampTransform.outputSize(4000, 3000, 4000, 0)) // == cap
        assertEquals(3000 to 2250, StampTransform.outputSize(3000, 2250, 4000, 0)) // below cap: no upscale
        assertEquals(4000 to 3000, StampTransform.outputSize(8000, 6000, 4000, 0)) // exact halving
        assertEquals(2000 to 1500, StampTransform.outputSize(8000, 6000, 2000, 0)) // exact quarter
        assertEquals(4000 to 3000, StampTransform.outputSize(8160, 6120, 4000, 0)) // scale + round
        assertEquals(3000 to 4000, StampTransform.outputSize(8000, 6000, 4000, 90))
        assertEquals(4000 to 3000, StampTransform.outputSize(8000, 6000, 4000, 180))
        assertEquals(3000 to 2250, StampTransform.outputSize(3000, 4000, 3000, 270)) // portrait scaled, then swapped
        assertEquals(4000 to 2250, StampTransform.outputSize(4001, 2251, 4000, 0)) // 2250.44 -> 2250
    }

    @Test
    fun outputSize_rounding_and_validation() {
        assertEquals(4000 to 2250, StampTransform.outputSize(4002, 2251, 4000, 0)) // 2249.87 -> 2250
        assertEquals(4000 to 1, StampTransform.outputSize(9000, 1, 4000, 0)) // never 0
        assertFailsWith<IllegalArgumentException> { StampTransform.outputSize(4000, 3000, 4000, 45) }
        assertFailsWith<IllegalArgumentException> { StampTransform.outputSize(0, 3000, 4000, 0) }
    }

    @Test
    fun exactSample() {
        assertEquals(1, StampTransform.exactSample(4000, 4000))
        assertEquals(2, StampTransform.exactSample(8000, 4000))
        assertEquals(4, StampTransform.exactSample(8000, 2000))
        assertEquals(0, StampTransform.exactSample(8160, 4000))
        assertEquals(0, StampTransform.exactSample(4000, 3000))
    }

    @Test
    fun affineComposition_matchesSequentialApplication() {
        val a = Affine(0.0, -1.0, 1.0, 0.0, 7.0, 0.0)
        val b = Affine(2.0, 0.0, 0.0, 3.0, 1.0, -1.0)
        val ab = a.then(b)
        for ((x, y) in listOf(0.0 to 0.0, 1.5 to 2.5, -3.0 to 4.0)) {
            assertEquals(b.mapX(a.mapX(x, y), a.mapY(x, y)), ab.mapX(x, y))
            assertEquals(b.mapY(a.mapX(x, y), a.mapY(x, y)), ab.mapY(x, y))
        }
        val p = a.preTranslate(0.0, 10.0).preScale(2.0, 2.0)
        assertEquals(a.mapX(2.0 * 3, 2.0 * 4 + 10), p.mapX(3.0, 4.0))
        assertEquals(a.mapY(2.0 * 3, 2.0 * 4 + 10), p.mapY(3.0, 4.0))
    }
}
