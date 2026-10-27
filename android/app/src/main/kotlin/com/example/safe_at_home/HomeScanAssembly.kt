package com.example.safe_at_home

internal object HomeScanAssembly {
    data class Room(val geometry: BathroomScanGeometry, val toShared: FloatArray, val depth: Boolean)
    fun encode(request: HomeScanRequest, snapshots: List<Room>, capturedAt: String,
        encode: (Map<String, Any>) -> String): String {
        require(snapshots.size == request.rooms.size)
        require(snapshots.indices.all { snapshots[it].geometry.scanId == request.rooms[it].token })
        val merged = BathroomScanGeometry(request.id)
        val roomBudget = (HomeScanRequest.MAX_JSON_BYTES - 132 * 1024) / snapshots.size
        fun bounded(geometry: BathroomScanGeometry, depth: Boolean, bytes: Int): Map<String, Any> {
            var selected: Map<String, Any>? = null
            check(geometry.encodeSceneWithinLimit(capturedAt, depth, bytes) { candidate ->
                selected = candidate
                encode(candidate)
            } != null)
            return selected!!
        }
        val rooms = snapshots.mapIndexed { i, snapshot ->
            val common = BathroomScanGeometry(request.rooms[i].token)
            common.absorb(snapshot.geometry, snapshot.toShared)
            check(common.elementCount > 0 || common.pointCount >= 20)
            val identity = FloatArray(16) { if (it % 5 == 0) 1f else 0f }
            merged.absorb(common, identity)
            common.capPointSamples(minOf(BathroomScanGeometry.MAX_POINTS, 8192 / snapshots.size))
            mapOf("token" to request.rooms[i].token, "scene" to bounded(common, snapshot.depth, roomBudget))
        }
        val payload = encode(mapOf("version" to 1, "sessionId" to request.id, "rooms" to rooms,
            "merged" to bounded(merged, snapshots.any { it.depth }, 128 * 1024)))
        check(payload.toByteArray(Charsets.UTF_8).size <= HomeScanRequest.MAX_JSON_BYTES)
        return payload
    }
}
