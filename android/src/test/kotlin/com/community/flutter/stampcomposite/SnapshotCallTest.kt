package com.community.flutter.stampcomposite

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertIs
import kotlin.test.assertTrue

/**
 * The Android mini-map's call lifecycle: one reply at most, the view always torn down, nothing after a
 * cancel, and no reply at all when the engine is gone.
 */
internal class SnapshotCallTest {
    private class Probe {
        val replies = mutableListOf<Any>()
        var teardowns = 0
        fun call() = SnapshotCall { replies.add(it) }.also { c -> c.onTeardown { teardowns++ } }
    }

    @Test
    fun finishRepliesOnceAndTearsDown() {
        val p = Probe()
        val c = p.call()
        assertTrue(c.finish(byteArrayOf(1, 2)))
        assertFalse(c.finish(StampException("COMPOSITE", "map snapshot timed out")), "the timeout after success is dropped")
        assertEquals(1, p.replies.size)
        assertEquals(1, p.teardowns)
        assertTrue(c.isDone)
    }

    @Test
    fun activityDetachCancelsWithAnErrorReplyThenDropsLateCallbacks() {
        val p = Probe()
        val c = p.call()
        c.cancel(reply = true)
        assertFalse(c.finish(byteArrayOf(9)), "a late snapshot / encode after the detach is dropped")
        assertEquals(1, p.replies.size)
        val e = assertIs<StampException>(p.replies.single())
        assertEquals("COMPOSITE", e.code)
        assertEquals(1, p.teardowns)
    }

    @Test
    fun engineDetachCancelsSilently() {
        val p = Probe()
        val c = p.call()
        c.cancel(reply = false)
        c.finish(byteArrayOf(9))
        c.cancel(reply = true)
        assertTrue(p.replies.isEmpty(), "no reply ever reaches a dead engine")
        assertEquals(1, p.teardowns)
    }

    @Test
    fun teardownAddedAfterTheEndRunsAtOnceAndAFailingTeardownDoesNotBlockTheReply() {
        val replies = mutableListOf<Any>()
        val c = SnapshotCall { replies.add(it) }
        c.onTeardown { throw IllegalStateException("view already gone") }
        c.finish("ok")
        assertEquals(listOf<Any>("ok"), replies)
        var late = 0
        c.onTeardown { late++ }
        assertEquals(1, late)
    }

    @Test
    fun registryCancelsEveryInFlightCallAndForgetsFinishedOnes() {
        val calls = SnapshotCalls()
        val a = Probe()
        val b = Probe()
        val ca = a.call()
        val cb = b.call()
        calls.add(ca)
        calls.add(cb)
        assertEquals(2, calls.size)
        ca.finish(byteArrayOf(1))
        assertEquals(1, calls.size, "a finished call leaves the registry")
        calls.cancelAll(reply = false)
        assertEquals(0, calls.size)
        assertTrue(b.replies.isEmpty())
        assertEquals(1, b.teardowns)
        val done = SnapshotCall {}.also { it.finish(0) }
        calls.add(done)
        assertEquals(0, calls.size, "an already finished call is never registered")
    }
}
