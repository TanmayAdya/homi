package com.example.safe_at_home

internal data class HomeScanRequest(val id: String, val language: String, val rooms: List<Room>) {
    data class Room(val token: String, val name: String)
    companion object {
        const val MAX_JSON_BYTES = 360 * 1024
        fun parse(value: Any?): HomeScanRequest? {
            val v = value as? Map<*, *> ?: return null
            if (v.keys != setOf("scanId", "languageCode", "rooms")) return null
            val id = v["scanId"] as? String ?: return null
            val language = v["languageCode"] as? String ?: return null
            val raw = v["rooms"] as? List<*> ?: return null
            if (!BathroomScanGeometry.isScanId(id) || language !in setOf("en", "es", "zh-Hans", "zh-Hant", "vi", "fil") || raw.size !in 2..8) return null
            val seen = mutableSetOf<String>()
            val rooms = raw.map { entry ->
                val room = entry as? Map<*, *> ?: return null
                if (room.keys != setOf("token", "name")) return null
                val token = room["token"] as? String ?: return null
                val name = room["name"] as? String ?: return null
                if (!BathroomScanGeometry.isScanId(token) || !seen.add(token.lowercase(java.util.Locale.ROOT)) ||
                    name.isBlank() || name != name.trim() || name.codePointCount(0, name.length) > 80 ||
                    name.any { it.code < 32 || it.code in 127..159 || it.code in 0x2028..0x202e || it.code in 0x2066..0x2069 }) return null
                Room(token, name)
            }
            return HomeScanRequest(id, language, rooms)
        }
    }
}
