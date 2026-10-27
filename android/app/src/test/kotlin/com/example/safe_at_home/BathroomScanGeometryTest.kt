package com.example.safe_at_home

import org.junit.Assert.*
import org.junit.Test
import java.nio.ByteBuffer
import java.nio.ByteOrder

class BathroomScanGeometryTest {
    private val scanId = "037f1173-a7b2-4921-ae11-36aac11b8ba0"

    @Test fun `localized start accepts only supported language codes and cancel remains strict`() {
        for (language in listOf("en", "es", "zh-Hans", "zh-Hant", "vi", "fil")) {
            val request = mapOf("scanId" to scanId, "languageCode" to language)
            assertEquals(scanId, bathroomScanRequestId(request, allowLanguage = true))
            assertNull(bathroomScanRequestId(request))
        }
        assertNull(bathroomScanRequestId(mapOf("scanId" to scanId, "languageCode" to "unknown"), allowLanguage = true))
        assertNull(bathroomScanRequestId(mapOf("scanId" to scanId, "languageCode" to "es", "caseId" to scanId), allowLanguage = true))
        assertEquals("Cancelar escaneo", AppScanTranslations.text("Cancel scan", "es"))
        assertEquals("取消掃描", AppScanTranslations.text("Cancel scan", "zh-Hant"))
        val notice = AppScanTranslations.text("This application runs on Google Play Services for AR (ARCore), which is provided by Google and governed by the Google Privacy Policy.", "vi")
        assertTrue(notice.contains("Google Play Services for AR"))
        assertTrue(notice.contains("Google Privacy Policy"))
    }
    @Test fun `room context is bounded display copy and never authorizes outdoor capture`() {
        for (type in RoomScanContext.Type.entries) {
            val room = mapOf("type" to type.name, "name" to "Fictional ${type.name}")
            val request = mapOf("scanId" to scanId, "room" to room, "languageCode" to "en")
            assertEquals(scanId, bathroomScanRequestId(request, allowLanguage = true))
            assertNull(bathroomScanRequestId(request))
            assertEquals(type, RoomScanContext.parse(room)?.type)
        }
        for (room in listOf(
            mapOf("type" to "outdoorPaths", "name" to "Outside"),
            mapOf("type" to "bedroom", "name" to "Bad\nname"),
            mapOf("type" to "bedroom", "name" to "x".repeat(81)),
            mapOf("type" to "bedroom", "name" to "Bedroom", "id" to "private-id"),
        )) {
            assertNull(bathroomScanRequestId(mapOf("scanId" to scanId, "room" to room), allowLanguage = true))
        }
    }

    private fun identity() = floatArrayOf(1f, 0f, 0f, 0f, 0f, 1f, 0f, 0f, 0f, 0f, 1f, 0f, 0f, 0f, 0f, 1f)

    @Test fun `scan identity rejects malformed and non-v4 identifiers`() {
        assertTrue(BathroomScanGeometry.isScanId(scanId))
        assertFalse(BathroomScanGeometry.isScanId(null))
        assertFalse(BathroomScanGeometry.isScanId("../private-case"))
        assertFalse(BathroomScanGeometry.isScanId(scanId.replace("4921", "1921")))
        assertFalse(BathroomScanGeometry.isScanId(scanId + "\n"))
    }

    @Test fun `plane dimensions preserve unmeasured thickness and do not claim semantics`() {
        val geometry = BathroomScanGeometry(scanId)
        assertTrue(geometry.addPlane("plane1", "horizontal_upward", 3f, 2f, identity()))
        val plane = geometry.planeSamples().single().toMap()
        assertEquals(listOf(3.0, 0.0, 2.0), plane["dimensions"])
        assertEquals("unknown", plane["kind"])
        assertEquals("unknown", plane["classificationConfidence"])
        assertEquals("horizontal_upward", plane["nativeCategory"])
    }

    @Test fun `invalid and reflected transforms cannot become retained geometry`() {
        val geometry = BathroomScanGeometry(scanId)
        val cases = listOf(
            identity().apply { this[0] = -1f },
            identity().apply { this[0] = 2f },
            identity().apply { this[4] = 0.1f },
            identity().apply { this[3] = 1f },
            identity().apply { this[12] = 51f },
            identity().apply { this[5] = Float.NaN },
            FloatArray(15),
        )
        cases.forEach { assertFalse(geometry.addPlane("bad", "vertical", 1f, 1f, it)) }
        assertEquals(0, geometry.elementCount)
        assertTrue((geometry.scene("2026-10-24T00:00:00.000Z", true)["warnings"] as List<*>).contains("geometry_omitted"))
    }

    @Test fun `plane replacement and subsumption preserve stable identity and release count`() {
        val geometry = BathroomScanGeometry(scanId)
        geometry.addPlane("plane1", "vertical", 1f, 2f, identity())
        geometry.addPlane("plane1", "vertical", 2f, 2f, identity())
        assertEquals(1, geometry.elementCount)
        assertEquals(2.0, geometry.planeSamples().single().dimensions[0], 0.0)
        geometry.removePlane("plane1")
        assertEquals(0, geometry.elementCount)
    }

    @Test fun `plane count is bounded and retained planes can still refine after limit`() {
        val geometry = BathroomScanGeometry(scanId)
        repeat(BathroomScanGeometry.MAX_ELEMENTS) { geometry.addPlane("plane$it", "vertical", 1f, 2f, identity()) }
        assertFalse(geometry.addPlane("extra", "vertical", 1f, 2f, identity()))
        assertTrue(geometry.truncated)
        assertEquals(BathroomScanGeometry.MAX_ELEMENTS, geometry.elementCount)
        assertTrue(geometry.addPlane("plane0", "vertical", 2f, 2f, identity()))
        assertEquals(2.0, geometry.planeSamples().first().dimensions[0], 0.0)
    }

    @Test fun `point samples filter invalid bounds and confidence while retaining zero coordinates`() {
        val geometry = BathroomScanGeometry(scanId)
        assertTrue(geometry.addPoint(0f, 0f, 0f, 0.5f))
        assertFalse(geometry.addPoint(1f, 0f, 0f, 0.49f))
        assertFalse(geometry.addPoint(Float.NaN, 0f, 0f, 1f))
        assertFalse(geometry.addPoint(51f, 0f, 0f, 1f))
        assertFalse(geometry.addPoint(1f, 0f, 0f, 1.1f))
        assertEquals(listOf(0.0, 0.0, 0.0, 0.5), geometry.pointSamples().single())
    }

    @Test fun `voxel samples prefer actual higher confidence and bound observed sample count`() {
        val geometry = BathroomScanGeometry(scanId)
        assertTrue(geometry.addPoint(0.001f, 0f, 0f, 0.5f))
        assertFalse(geometry.addPoint(0.002f, 0f, 0f, 0.5f))
        assertTrue(geometry.addPoint(0.002f, 0f, 0f, 0.9f))
        assertEquals(1, geometry.pointCount)
        repeat(BathroomScanGeometry.MAX_POINTS + 20) { index ->
            geometry.addPoint((index % 100) * 0.1f, (index / 100) * 0.1f, 1f, 1f)
        }
        assertEquals(BathroomScanGeometry.MAX_POINTS, geometry.pointCount)
        assertTrue(geometry.truncated)
    }

    @Test fun `depth unprojection uses camera-plane distance right-handed y-up and translation`() {
        val transform = identity().apply { this[12] = 1f; this[13] = 2f; this[14] = 3f }
        val center = BathroomScanGeometry.unprojectDepth(50, 50, 2000, 100f, 100f, 50f, 50f, transform)
        assertArrayEquals(floatArrayOf(1f, 2f, 1f), center, 0.0001f)
        val upperRight = BathroomScanGeometry.unprojectDepth(100, 0, 2000, 100f, 100f, 50f, 50f, transform)
        assertArrayEquals(floatArrayOf(2f, 3f, 1f), upperRight, 0.0001f)
        assertNull(BathroomScanGeometry.unprojectDepth(50, 50, 0, 100f, 100f, 50f, 50f, transform))
        assertNull(BathroomScanGeometry.unprojectDepth(50, 50, 2000, 0f, 100f, 50f, 50f, transform))
    }

    @Test fun `depth unprojection respects a rotated camera rather than treating depth as world z`() {
        val rotationY = floatArrayOf(0f, 0f, -1f, 0f, 0f, 1f, 0f, 0f, 1f, 0f, 0f, 0f, 0f, 0f, 0f, 1f)
        assertArrayEquals(floatArrayOf(-2f, 0f, 0f), BathroomScanGeometry.unprojectDepth(50, 50, 2000, 100f, 100f, 50f, 50f, rotationY), 0.0001f)
    }

    @Test fun `scene always declares incomplete coverage and actual source with bounded warning tokens`() {
        val geometry = BathroomScanGeometry(scanId)
        repeat(100) { geometry.markTrackingLimited() }
        val scene = geometry.scene("2026-10-24T00:00:00.000Z", false)
        assertEquals("arcore", scene["source"])
        assertEquals("partial", scene["coverage"])
        assertEquals("right_handed_y_up", scene["coordinateSystem"])
        assertEquals(listOf("tracking_limited", "depth_unavailable"), scene["warnings"])
        assertEquals(12, scene.size)
    }

    @Test fun `plane center inside bounds cannot hide corners outside the shared scene bounds`() {
        val geometry = BathroomScanGeometry(scanId)
        val translated = identity().apply { this[12] = 49f }
        assertFalse(geometry.addPlane("wide", "horizontal_upward", 4f, 4f, translated))
        assertTrue(geometry.addPlane("edge", "horizontal_upward", 2f, 2f, translated))
        assertEquals(1, geometry.elementCount)
        val rotated = floatArrayOf(.70710677f, 0f, -.70710677f, 0f, 0f, 1f, 0f, 0f, .70710677f, 0f, .70710677f, 0f, 49f, 0f, 0f, 1f)
        assertFalse(geometry.addPlane("rotated", "vertical", 2f, 2f, rotated))
    }

    @Test fun `invalid refinement removes the older plane rather than retaining stale geometry`() {
        val geometry = BathroomScanGeometry(scanId)
        assertTrue(geometry.addPlane("plane", "vertical", 1f, 2f, identity()))
        assertFalse(geometry.addPlane("plane", "vertical", 4f, 4f, identity().apply { this[12] = 49f }))
        assertEquals(0, geometry.elementCount)
        assertTrue((geometry.scene("2026-10-24T00:00:00.000Z", false)["warnings"] as List<*>).contains("geometry_omitted"))
    }

    @Test fun `native affine and identifier validation matches strict shared scene boundaries`() {
        val geometry = BathroomScanGeometry(scanId)
        listOf(3, 7, 11).forEach { index ->
            assertFalse(geometry.addPlane("perspective", "vertical", 1f, 1f, identity().apply { this[index] = .0002f }))
        }
        assertFalse(geometry.addPlane("affine", "vertical", 1f, 1f, identity().apply { this[15] = 1.0002f }))
        listOf(" leading", "trailing ", "line\nbreak", "control\u007f").forEach {
            assertFalse(geometry.addPlane(it, "vertical", 1f, 1f, identity()))
        }
        assertEquals(0, geometry.elementCount)
    }

    @Test fun `depth plane reader respects offset padding little endian and unsigned confidence`() {
        val depth = ByteBuffer.allocate(24).order(ByteOrder.BIG_ENDIAN)
        depth.position(3)
        depth.put(3, 0xd0.toByte()); depth.put(4, 0x07)
        depth.put(7, 0xff.toByte()); depth.put(8, 0xff.toByte())
        depth.put(13, 0x2c); depth.put(14, 0x01)
        assertEquals(2000, BathroomScanGeometry.readPlaneValue(depth, 2, 2, 10, 4, 0, 0, 2))
        assertEquals(65535, BathroomScanGeometry.readPlaneValue(depth, 2, 2, 10, 4, 1, 0, 2))
        assertEquals(300, BathroomScanGeometry.readPlaneValue(depth, 2, 2, 10, 4, 0, 1, 2))
        assertEquals(3, depth.position())
        val confidence = ByteBuffer.wrap(byteArrayOf(0, 0, 255.toByte(), 128.toByte())).apply { position(2) }
        assertEquals(255, BathroomScanGeometry.readPlaneValue(confidence, 2, 1, 2, 1, 0, 0, 1))
        assertEquals(128, BathroomScanGeometry.readPlaneValue(confidence, 2, 1, 2, 1, 1, 0, 1))
    }

    @Test fun `malformed image layouts fail closed without overflowing offsets or reading beyond limit`() {
        val buffer = ByteBuffer.allocate(16).apply { position(4); limit(12) }
        assertNull(BathroomScanGeometry.readPlaneValue(buffer, 2, 2, 8, 2, 0, 1, 2))
        assertNull(BathroomScanGeometry.readPlaneValue(buffer, 2, 2, 3, 2, 0, 0, 2))
        assertNull(BathroomScanGeometry.readPlaneValue(buffer, 2, 2, 8, 1, 0, 0, 2))
        assertNull(BathroomScanGeometry.readPlaneValue(buffer, 2, 2, 8, 2, -1, 0, 2))
        assertNull(BathroomScanGeometry.readPlaneValue(buffer, 2, 2, 8, 2, 2, 0, 2))
        assertNull(BathroomScanGeometry.readPlaneValue(buffer, Int.MAX_VALUE, Int.MAX_VALUE, Int.MAX_VALUE, 2, 0, 0, 2))
        assertNull(BathroomScanGeometry.readPlaneValue(buffer, 1, Int.MAX_VALUE, Int.MAX_VALUE, 2, 0, Int.MAX_VALUE - 1, 2))
    }

    @Test fun `bounded export preserves reviewed feature candidates and spreads retained points across the capture`() {
        val geometry = BathroomScanGeometry(scanId)
        val transform = floatArrayOf(2f / 3, 2f / 3, -1f / 3, 0f, -1f / 3, 2f / 3, 2f / 3, 0f, 2f / 3, -1f / 3, 2f / 3, 0f, 47.234567f, -47.234567f, 47.234567f, 1f)
        repeat(BathroomScanGeometry.MAX_ELEMENTS) { index ->
            assertTrue(geometry.addPlane("plane${index.toString().padStart(75, '0')}", "horizontal_downward", 1.234567f, 1.234567f, transform))
        }
        repeat(BathroomScanGeometry.MAX_POINTS) { index ->
            assertTrue(geometry.addPoint(20.123456f + index % 64 * .111111f, 20.123456f + index / 64 * .111111f, -22.654321f, .765432f))
        }
        val original = geometry.scene("2026-10-24T00:00:00.000Z", true)
        assertTrue(json(original).toByteArray().size > BathroomScanGeometry.MAX_JSON_BYTES)
        var exported: Map<String, Any>? = null
        var encodingPasses = 0
        val encoded = geometry.encodeSceneWithinLimit("2026-10-24T00:00:00.000Z", true) {
            exported = it
            encodingPasses++
            json(it)
        }
        assertNotNull(encoded)
        assertTrue(encoded!!.toByteArray().size <= BathroomScanGeometry.MAX_JSON_BYTES)
        assertTrue(encodingPasses <= 24)
        assertEquals(original["elements"], exported!!["elements"])
        assertEquals(true, exported!!["truncated"])
        assertTrue((exported!!["warnings"] as List<*>).contains("geometry_omitted"))
        val points = exported!!["points"] as List<*>
        assertTrue(points.size in 20 until BathroomScanGeometry.MAX_POINTS)
        assertEquals(geometry.pointSamples().first(), points.first())
        assertEquals(geometry.pointSamples().last(), points.last())
        assertEquals(BathroomScanGeometry.MAX_POINTS, geometry.pointCount)
        assertFalse(geometry.truncated)
    }

    @Test fun `small export does not claim omitted geometry or mutate the original scene`() {
        val geometry = BathroomScanGeometry(scanId)
        geometry.addPlane("plane", "vertical", 1f, 2f, identity())
        val expected = geometry.scene("2026-10-24T00:00:00.000Z", false)
        assertEquals(json(expected), geometry.encodeSceneWithinLimit("2026-10-24T00:00:00.000Z", false, ::json))
    }

    @Test fun `strict native request accepts only the scoped scan UUID field`() {
        assertEquals(scanId, bathroomScanRequestId(mapOf("scanId" to scanId)))
        listOf(null, emptyMap<String, Any>(), mapOf("scanId" to 1), mapOf("scanId" to "bad"),
            mapOf("scanId" to scanId, "path" to "private"), listOf(scanId)).forEach {
            assertNull(bathroomScanRequestId(it))
        }
    }

    @Test fun `scrollable scan controls leave camera visible in short and inset landscape viewports`() {
        assertEquals(280, bathroomScanControlsHeight(800, 280))
        assertEquals(136, bathroomScanControlsHeight(272, 280))
        assertEquals(60, bathroomScanControlsHeight(120, 280))
        assertEquals(840, bathroomScanControlsHeight(2400, 840))
        assertEquals(0, bathroomScanControlsHeight(-20, 280))
        assertEquals(0, bathroomScanControlsHeight(800, -1))
        for (height in 0..1200) {
            val controls = bathroomScanControlsHeight(height, 280)
            assertTrue(controls >= 0 && controls <= height / 2)
        }
    }

    private fun json(value: Any?): String = when (value) {
        is Map<*, *> -> value.entries.joinToString(",", "{", "}") { json(it.key) + ":" + json(it.value) }
        is List<*> -> value.joinToString(",", "[", "]", transform = ::json)
        is String -> "\"" + value.replace("\\", "\\\\").replace("\"", "\\\"") + "\""
        null -> "null"
        else -> value.toString()
    }
}
