package com.example.safe_at_home

import android.Manifest
import android.app.Activity
import android.content.Intent
import android.content.pm.PackageManager
import android.os.Handler
import android.os.Looper
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel
import org.json.JSONArray
import org.json.JSONObject

class BathroomScanPlatform(private val activity: Activity, messenger: BinaryMessenger) {
    private val channel = MethodChannel(messenger, "safe_at_home/bathroom_scan")
    private var pending: MethodChannel.Result? = null
    private var pendingId: String? = null
    private var pendingRequestCode: Int? = null
    private var pendingHome: HomeScanRequest? = null
    private var nextRequestCode = REQUEST_CODE
    private var detached = false
    private val availability = bathroomScanAvailabilityLookup(activity, Handler(Looper.getMainLooper()))

    fun register() {
        channel.setMethodCallHandler { call, result ->
            when (call.method) {
                "capabilities" -> availability.check { supported ->
                    result.success(bathroomScanCapabilities(
                        supported,
                        activity.checkSelfPermission(Manifest.permission.CAMERA) == PackageManager.PERMISSION_GRANTED,
                    ))
                }
                "homeCapabilities" -> availability.check { supported ->
                    result.success(mapOf("supported" to (supported?.isSupported == true)))
                }
                "start", "startHome" -> {
                    val home = if (call.method == "startHome") HomeScanRequest.parse(call.arguments) else null
                    val id = if (call.method == "startHome") home?.id else bathroomScanRequestId(call.arguments, allowLanguage = true)
                    if (id == null) {
                        result.error("scan_failed", "The scan request is invalid.", null)
                    } else if (pending != null) {
                        result.error("scan_busy", "A room scan is already open.", null)
                    } else {
                        pendingId = id
                        pending = result
                        pendingHome = home
                        val requestCode = nextRequestCode++
                        if (nextRequestCode > LAST_REQUEST_CODE) nextRequestCode = REQUEST_CODE
                        pendingRequestCode = requestCode
                        try {
                            val intent = Intent(activity, BathroomScanActivity::class.java).putExtra(EXTRA_SCAN_ID, id)
                                .putExtra(EXTRA_LANGUAGE, (call.arguments as? Map<*, *>)?.get("languageCode") as? String ?: "en")
                                .putExtra(EXTRA_ROOM_NAME, RoomScanContext.parse((call.arguments as? Map<*, *>)?.get("room"))?.name)
                            if (home != null) {
                                intent.putExtra(EXTRA_HOME, true)
                                    .putStringArrayListExtra(EXTRA_ROOM_TOKENS, ArrayList(home.rooms.map { it.token }))
                                    .putStringArrayListExtra(EXTRA_ROOM_NAMES, ArrayList(home.rooms.map { it.name }))
                            }
                            activity.startActivityForResult(intent, requestCode)
                        } catch (_: Exception) {
                            completeError("scan_unavailable", "Room scanning could not be opened.")
                        }
                    }
                }
                "cancel" -> {
                    val id = bathroomScanRequestId(call.arguments)
                    if (id == null) {
                        result.error("scan_failed", "The scan request is invalid.", null)
                    } else {
                        if (id == pendingId) finishPendingActivity("scan_cancelled", "Room scan cancelled.")
                        result.success(null)
                    }
                }
                else -> result.notImplemented()
            }
        }
    }

    fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?): Boolean {
        if (requestCode !in REQUEST_CODE..LAST_REQUEST_CODE) return false
        if (requestCode != pendingRequestCode) return true
        val result = pending ?: return true
        val expected = pendingId
        val home = pendingHome
        pending = null
        pendingId = null
        pendingRequestCode = null
        pendingHome = null
        if (detached) return true
        if (resultCode != Activity.RESULT_OK || data?.getStringExtra(EXTRA_SCAN_ID) != expected) {
            val code = data?.getStringExtra(EXTRA_ERROR)?.takeIf { it in ERROR_CODES }
                ?: "scan_interrupted"
            result.error(code, messageFor(code), null)
            return true
        }
        try {
            val text = data?.getStringExtra(EXTRA_SCENE) ?: error("missing scene")
            require(text.toByteArray(Charsets.UTF_8).size <= if (home == null) BathroomScanGeometry.MAX_JSON_BYTES else HomeScanRequest.MAX_JSON_BYTES)
            val json = JSONObject(text)
            if (home == null) require(json.getString("scanId") == expected)
            else {
                require(json.keys().asSequence().toSet() == setOf("version", "sessionId", "rooms", "merged"))
                require(json.getInt("version") == 1 && json.getString("sessionId") == expected)
                val rooms = json.getJSONArray("rooms")
                require(rooms.length() == home.rooms.size)
                home.rooms.forEachIndexed { i, room ->
                    val item = rooms.getJSONObject(i)
                    require(item.keys().asSequence().toSet() == setOf("token", "scene"))
                    require(item.getString("token") == room.token && item.getJSONObject("scene").getString("scanId") == room.token)
                    require(item.getJSONObject("scene").getString("source") == "arcore")
                }
                require(json.getJSONObject("merged").getString("scanId") == expected && json.getJSONObject("merged").getString("source") == "arcore")
            }
            result.success(toCodecValue(json))
        } catch (_: Exception) {
            result.error("scan_failed", "The scan could not be read. Please scan again.", null)
        }
        return true
    }

    fun detach() {
        detached = true
        channel.setMethodCallHandler(null)
        availability.close()
        finishPendingActivity("scan_interrupted", "The scan was interrupted. Please scan again.")
    }

    private fun finishPendingActivity(code: String, message: String) {
        try {
            pendingRequestCode?.let { activity.finishActivity(it) }
        } catch (_: Exception) {
        } finally {
            completeError(code, message)
        }
    }

    private fun completeError(code: String, message: String) {
        val result = pending
        pending = null
        pendingId = null
        pendingRequestCode = null
        pendingHome = null
        result?.error(code, message, null)
    }

    private fun toCodecValue(value: Any?): Any? = when (value) {
        JSONObject.NULL -> null
        is JSONObject -> value.keys().asSequence().associateWith { toCodecValue(value.get(it)) }
        is JSONArray -> (0 until value.length()).map { toCodecValue(value.get(it)) }
        else -> value
    }

    companion object {
        const val REQUEST_CODE = 21314
        private const val LAST_REQUEST_CODE = 21825
        const val EXTRA_SCAN_ID = "sah.scan.id"
        const val EXTRA_LANGUAGE = "sah.scan.language"
        const val EXTRA_ROOM_NAME = "sah.scan.room.name"
        const val EXTRA_SCENE = "sah.scan.scene"
        const val EXTRA_HOME = "sah.scan.home"
        const val EXTRA_ROOM_TOKENS = "sah.scan.home.tokens"
        const val EXTRA_ROOM_NAMES = "sah.scan.home.names"
        const val EXTRA_ERROR = "sah.scan.error"
        private val ERROR_CODES = setOf(
            "scan_cancelled", "scan_interrupted", "scan_unavailable", "scan_permission_denied",
            "scan_busy", "scan_failed", "scan_limit",
        )
        fun messageFor(code: String): String = when (code) {
            "scan_cancelled" -> "Room scan cancelled."
            "scan_interrupted" -> "The scan was interrupted. Please scan again."
            "scan_unavailable" -> "ARCore scanning is unavailable. Photos and manual measurements still work."
            "scan_permission_denied" -> "Camera access is needed to scan. You can use manual measurements instead."
            "scan_limit" -> "The scan reached its time, size or device resource limit. Let the device rest, then try a smaller area."
            else -> "The scan could not be completed. Please try again."
        }
    }
}

internal fun bathroomScanRequestId(arguments: Any?, allowLanguage: Boolean = false): String? {
    val values = arguments as? Map<*, *> ?: return null
    if (!values.containsKey("scanId")) return null
    val allowed = if (allowLanguage) setOf("scanId", "languageCode", "room") else setOf("scanId")
    if (!allowed.containsAll(values.keys)) return null
    if (values.containsKey("room") && RoomScanContext.parse(values["room"]) == null) return null
    if (values.containsKey("languageCode") && (!allowLanguage || values["languageCode"] !in setOf("en", "es", "zh-Hans", "zh-Hant", "vi", "fil"))) return null
    val id = values["scanId"] as? String ?: return null
    return id.takeIf { BathroomScanGeometry.isScanId(it) }
}

internal data class RoomScanContext(val type: Type, val name: String) {
    enum class Type { bathroom, entrance, stairs, livingSpaces, bedroom, kitchen }
    companion object {
        fun parse(value: Any?): RoomScanContext? {
            val room = value as? Map<*, *> ?: return null
            if (room.keys != setOf("type", "name")) return null
            val type = Type.entries.firstOrNull { it.name == room["type"] } ?: return null
            val name = room["name"] as? String ?: return null
            if (name.isEmpty() || name.trim() != name || name.codePointCount(0, name.length) > 80 ||
                name.any { it.code < 32 || it.code in 127..159 || it.code in 0x2028..0x202e || it.code in 0x2066..0x2069 }) return null
            return RoomScanContext(type, name)
        }
    }
}
