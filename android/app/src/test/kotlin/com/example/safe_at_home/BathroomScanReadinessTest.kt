package com.example.safe_at_home

import com.google.ar.core.ArCoreApk.Availability
import org.junit.Assert.*
import org.junit.Test

class BathroomScanReadinessTest {
    private class Harness {
        val queries = mutableListOf<(Availability?) -> Unit>()
        val timers = mutableListOf<() -> Unit>()
        var cancelledTimers = 0
        val lookup = BathroomScanAvailabilityLookup(
            query = { queries.add(it) },
            scheduleTimeout = { callback ->
                timers.add(callback)
                val cancel: () -> Unit = { cancelledTimers++ }
                cancel
            },
        )
    }

    @Test fun `permission and services setup remain supported without claiming depth`() {
        val cases = mapOf(
            Availability.SUPPORTED_INSTALLED to "permission_denied",
            Availability.SUPPORTED_NOT_INSTALLED to "services_missing",
            Availability.SUPPORTED_APK_TOO_OLD to "services_update_required",
        )
        cases.forEach { (availability, reason) ->
            val result = bathroomScanCapabilities(availability, false)
            assertEquals(true, result["supported"])
            assertEquals(reason, result["reason"])
            assertEquals("arcore", result["source"])
            assertNull(result["depthSupported"])
        }
        assertEquals("available", bathroomScanCapabilities(Availability.SUPPORTED_INSTALLED, true)["reason"])
    }

    @Test fun `unknown availability is not mislabeled as unsupported hardware`() {
        listOf(null, Availability.UNKNOWN_CHECKING, Availability.UNKNOWN_ERROR, Availability.UNKNOWN_TIMED_OUT).forEach {
            val result = bathroomScanCapabilities(it, true)
            assertEquals(false, result["supported"])
            assertEquals("checking", result["reason"])
        }
        assertEquals("unsupported_device", bathroomScanCapabilities(Availability.UNSUPPORTED_DEVICE_NOT_CAPABLE, true)["reason"])
    }

    @Test fun `concurrent checks share a query and all receive its settled result`() {
        val harness = Harness()
        val results = mutableListOf<Availability?>()
        repeat(3) { harness.lookup.check { results.add(it) } }
        assertEquals(1, harness.queries.size)
        assertEquals(1, harness.timers.size)
        assertTrue(results.isEmpty())
        harness.queries.single()(Availability.SUPPORTED_NOT_INSTALLED)
        assertEquals(List(3) { Availability.SUPPORTED_NOT_INSTALLED }, results)
        assertEquals(1, harness.cancelledTimers)
        harness.timers.single()()
        assertEquals(3, results.size)
    }

    @Test fun `timeout resolves unknown and stale response cannot complete a retry`() {
        val harness = Harness()
        val first = mutableListOf<Availability?>()
        val second = mutableListOf<Availability?>()
        harness.lookup.check { first.add(it) }
        harness.timers.single()()
        assertEquals(listOf<Availability?>(null), first)
        harness.lookup.check { second.add(it) }
        harness.queries.first()(Availability.UNSUPPORTED_DEVICE_NOT_CAPABLE)
        assertTrue(second.isEmpty())
        harness.queries.last()(Availability.SUPPORTED_INSTALLED)
        assertEquals(listOf(Availability.SUPPORTED_INSTALLED), second)
        assertEquals(1, first.size)
    }

    @Test fun `fresh check observes a later service or permission change`() {
        val harness = Harness()
        val results = mutableListOf<Availability?>()
        harness.lookup.check { results.add(it) }
        harness.queries.first()(Availability.SUPPORTED_NOT_INSTALLED)
        harness.lookup.check { results.add(it) }
        assertEquals(2, harness.queries.size)
        harness.queries.last()(Availability.SUPPORTED_INSTALLED)
        assertEquals(listOf(Availability.SUPPORTED_NOT_INSTALLED, Availability.SUPPORTED_INSTALLED), results)
    }

    @Test fun `detach clears pending callers and ignores subsequent native completion`() {
        val harness = Harness()
        val results = mutableListOf<Availability?>()
        harness.lookup.check { results.add(it) }
        harness.lookup.close()
        assertEquals(listOf<Availability?>(null), results)
        harness.queries.single()(Availability.SUPPORTED_INSTALLED)
        harness.timers.single()()
        assertEquals(1, results.size)
        harness.lookup.check { results.add(it) }
        assertEquals(listOf<Availability?>(null, null), results)
        assertEquals(1, harness.queries.size)
    }

    @Test fun `provider failure completes once and cancels timeout`() {
        var cancelled = false
        val lookup = BathroomScanAvailabilityLookup(
            query = { throw IllegalStateException("provider unavailable") },
            scheduleTimeout = { val cancel: () -> Unit = { cancelled = true }; cancel },
        )
        val results = mutableListOf<Availability?>()
        lookup.check { results.add(it) }
        assertEquals(listOf<Availability?>(null), results)
        assertTrue(cancelled)
    }

    @Test fun `completion callback can request another independent check`() {
        val harness = Harness()
        val results = mutableListOf<Availability?>()
        harness.lookup.check {
            results.add(it)
            harness.lookup.check { next -> results.add(next) }
        }
        harness.queries.first()(Availability.SUPPORTED_NOT_INSTALLED)
        assertEquals(2, harness.queries.size)
        harness.queries.last()(Availability.SUPPORTED_INSTALLED)
        assertEquals(listOf(Availability.SUPPORTED_NOT_INSTALLED, Availability.SUPPORTED_INSTALLED), results)
    }
}
