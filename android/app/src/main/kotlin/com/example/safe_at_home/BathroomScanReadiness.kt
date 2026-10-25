package com.example.safe_at_home

import android.content.Context
import android.os.Handler
import com.google.ar.core.ArCoreApk

internal class BathroomScanAvailabilityLookup(
    private val query: ((ArCoreApk.Availability?) -> Unit) -> Unit,
    private val scheduleTimeout: (() -> Unit) -> (() -> Unit),
) {
    private var request: Any? = null
    private var cancelTimeout: (() -> Unit)? = null
    private val waiting = mutableListOf<(ArCoreApk.Availability?) -> Unit>()
    private var closed = false

    fun check(complete: (ArCoreApk.Availability?) -> Unit) {
        if (closed) { complete(null); return }
        waiting.add(complete)
        if (request != null) return
        val identity = Any()
        request = identity
        cancelTimeout = scheduleTimeout { finish(identity, null) }
        try {
            query { finish(identity, it) }
        } catch (_: Exception) {
            finish(identity, null)
        }
    }

    private fun finish(identity: Any, availability: ArCoreApk.Availability?) {
        if (request !== identity) return
        request = null
        cancelTimeout?.invoke()
        cancelTimeout = null
        val callbacks = waiting.toList()
        waiting.clear()
        callbacks.forEach { it(availability) }
    }

    fun close() {
        closed = true
        request?.let { finish(it, null) }
    }
}

internal fun bathroomScanAvailabilityLookup(context: Context, handler: Handler): BathroomScanAvailabilityLookup {
    val application = context.applicationContext
    return BathroomScanAvailabilityLookup(
        query = { complete ->
            ArCoreApk.getInstance().checkAvailabilityAsync(application) { complete(it) }
        },
        scheduleTimeout = { complete ->
            val timeout = Runnable { complete() }
            handler.postDelayed(timeout, 3_000L)
            val cancel: () -> Unit = { handler.removeCallbacks(timeout) }
            cancel
        },
    )
}

internal fun bathroomScanCapabilities(
    availability: ArCoreApk.Availability?,
    cameraGranted: Boolean,
): Map<String, Any?> = mapOf(
    "supported" to (availability?.isSupported == true),
    "source" to "arcore",
    "reason" to when (availability) {
        ArCoreApk.Availability.SUPPORTED_INSTALLED -> if (cameraGranted) "available" else "permission_denied"
        ArCoreApk.Availability.SUPPORTED_NOT_INSTALLED -> "services_missing"
        ArCoreApk.Availability.SUPPORTED_APK_TOO_OLD -> "services_update_required"
        ArCoreApk.Availability.UNSUPPORTED_DEVICE_NOT_CAPABLE -> "unsupported_device"
        else -> "checking"
    },
    "depthSupported" to null,
)
