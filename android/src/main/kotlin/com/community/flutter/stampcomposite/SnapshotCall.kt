package com.community.flutter.stampcomposite

/**
 * One in-flight map snapshot, free of Android types so its lifecycle is JVM-tested: it replies AT MOST once,
 * always tears its view down, and after [cancel] never replies again (a late map callback, the PNG encode or the
 * timeout firing after the activity or the engine went away is dropped).
 *
 * - [finish]: the normal end (PNG bytes or a [StampException]); tears down, then replies.
 * - [cancel] with `reply = true`: the activity went away while the engine lives - tear down and answer the Dart side
 *   with a `COMPOSITE` error so its future completes (the stamp stays text only).
 * - [cancel] with `reply = false`: the engine is detached - tear down and DO NOT touch the reply (dead messenger).
 */
internal class SnapshotCall(private val reply: (Any) -> Unit) {
    private var done = false
    private val teardowns = mutableListOf<() -> Unit>()

    val isDone: Boolean get() = done

    /** Runs [block] on [finish] / [cancel] (or at once when the call already ended). */
    fun onTeardown(block: () -> Unit) {
        if (done) runQuietly(block) else teardowns.add(block)
    }

    /** True when this call delivered [outcome]; false when it had already ended. */
    fun finish(outcome: Any): Boolean {
        if (!end()) return false
        reply(outcome)
        return true
    }

    fun cancel(reply: Boolean) {
        if (!end()) return
        if (reply) reply(StampException("COMPOSITE", "map snapshot cancelled: the activity was detached"))
    }

    private fun end(): Boolean {
        if (done) return false
        done = true
        val list = teardowns.toList()
        teardowns.clear()
        list.forEach(::runQuietly)
        return true
    }

    private fun runQuietly(block: () -> Unit) {
        try {
            block()
        } catch (_: Throwable) {
        }
    }
}

/** The plugin's in-flight snapshots, so a detach can cancel every one of them. */
internal class SnapshotCalls {
    private val calls = mutableSetOf<SnapshotCall>()

    val size: Int get() = calls.size

    fun add(call: SnapshotCall) {
        if (call.isDone) return
        calls.add(call)
        call.onTeardown { calls.remove(call) }
    }

    fun cancelAll(reply: Boolean) {
        calls.toList().forEach { it.cancel(reply) }
        calls.clear()
    }
}
