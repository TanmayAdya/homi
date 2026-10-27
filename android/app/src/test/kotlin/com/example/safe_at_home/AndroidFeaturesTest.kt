package com.example.safe_at_home

import org.junit.Assert.*
import org.junit.Test
import java.util.UUID

class AndroidFeaturesTest {
    private val id = "037f1173-a7b2-4921-ae11-36aac11b8ba0"
    private val a = "1638832b-a045-4f37-821f-fbcae2e9222e"
    private val b = "c40d245d-e8ef-4463-8dd2-c7284e4441f1"
    private fun identity(x: Float = 0f) = FloatArray(16) { if (it % 5 == 0) 1f else 0f }.also { it[12] = x }
    private fun request(rooms: List<Map<String, String>> = listOf(
        mapOf("token" to a, "name" to "First bathroom"), mapOf("token" to b, "name" to "Second bathroom"),
    )) = mapOf("scanId" to id, "languageCode" to "en", "rooms" to rooms)
    private fun geometry(token: String, dense: Boolean = false) = BathroomScanGeometry(token).apply {
        addPlane("shared-wall", "vertical", 2f, 2f, identity())
        addPoint(1f, 0f, 0f, .75f)
        if (dense) repeat(4096) { i -> addPoint(i % 64 * .1f, i / 64 * .1f, 1f, .75f) }
    }

    @Test fun `Chat accepts only bounded UTF8 text and fresh request identifiers`() {
        val v = mapOf("requestId" to id, "locale" to "zh-Hant", "question" to "房間模型", "history" to "[]", "findings" to "[]")
        assertEquals("房間模型", PlanAssistantRequest.parse(v)!!.question)
        for (bad in listOf(v + ("accountId" to "private"), v + ("question" to " "),
            v + ("question" to "x".repeat(601)), v + ("history" to "x".repeat(2401)),
            v + ("locale" to "unsupported"), v + ("requestId" to "../private"),
            v + ("question" to "\uD800"),
            v + ("question" to "界".repeat(600)) + ("history" to "界".repeat(2400)) + ("findings" to "界".repeat(2400)))) {
            assertNull(PlanAssistantRequest.parse(bad))
        }
        assertNull(PlanAssistantRequest.requestId(mapOf("requestId" to id, "question" to "must not cross cancel")))
        assertTrue(planAssistantInstructions.contains("Never decide eligibility"))
        assertTrue(planAssistantInstructions.contains("You have no tools or actions"))
        assertTrue(planAssistantInstructions.contains("Rooms, choose the named room"))
    }
    @Test fun `home input rejects duplicate opaque room tokens and private extra fields`() {
        assertEquals(listOf(a, b), HomeScanRequest.parse(request())!!.rooms.map { it.token })
        assertNull(HomeScanRequest.parse(request() + ("caseId" to "forbidden")))
        assertNull(HomeScanRequest.parse(request(listOf(mapOf("token" to a, "name" to "Only one")))))
        assertNull(HomeScanRequest.parse(request(listOf(mapOf("token" to a, "name" to "One"), mapOf("token" to a.uppercase(), "name" to "Two")))))
        assertNull(HomeScanRequest.parse(request(listOf(mapOf("token" to a, "name" to "Bad\nname"), mapOf("token" to b, "name" to "Two")))))
        assertNull(HomeScanRequest.parse(request(List(9) { mapOf("token" to UUID.randomUUID().toString(), "name" to "Room") })))
    }
    @Test fun `context chat requires the exact bounded pair and uses shared navigation guide`() {
        val old = mapOf("requestId" to id, "locale" to "en", "question" to "Where next?", "history" to "[]", "findings" to "[]")
        val context = """{"version":2,"destination":"rooms","state":{},"sources":[{"id":"app.rooms"}]}"""
        val current = old + mapOf("appContext" to context, "guide" to "Shared app guide from Dart. Return strict JSON.")
        val request = PlanAssistantRequest.parse(current)!!
        assertEquals(context, request.appContext)
        assertNull(PlanAssistantRequest.parse(old)!!.appContext)
        assertTrue(planAssistantInstructionsFor(request).contains("Shared app guide from Dart"))
        assertTrue(planAssistantInstructionsFor(request).contains("You have no tools or actions"))
        assertFalse(planAssistantInstructionsFor(request).contains("Rooms, choose the named room"))
        for (bad in listOf(old + ("appContext" to context), old + ("guide" to "guide"),
            current + ("guide" to " "), current + ("appContext" to "x".repeat(16385)),
            current + ("appContext" to "界".repeat(5462)), current + ("guide" to "x".repeat(8193)),
            current + ("guide" to "界".repeat(2731)), current + ("guide" to "\uD800"),
            current + ("accountId" to "private"))) assertNull(PlanAssistantRequest.parse(bad))
        val valid = mapOf("text" to "Open Rooms.", "sourceIds" to listOf("app.rooms"), "openSourceId" to "app.rooms")
        assertTrue(PlanAssistantRequest.acceptsContextReply(valid, setOf("app.rooms")))
        for (bad in listOf(valid + ("route" to "admin"), valid + ("text" to "x".repeat(1201)),
            valid + ("sourceIds" to listOf("invented")), valid + ("sourceIds" to listOf("app.rooms", "app.rooms")),
            valid + ("openSourceId" to "invented"), valid + ("text" to "bad\u0000text"))) {
            assertFalse(PlanAssistantRequest.acceptsContextReply(bad, setOf("app.rooms")))
        }
    }
    @Test fun `anchor-local geometry is rigidly rebased without mutating its original or inventing classifications`() {
        val source = geometry(a)
        val before = source.scene("2026-10-25T00:00:00.000Z", false)
        val rotation = floatArrayOf(0f,0f,-1f,0f, 0f,1f,0f,0f, 1f,0f,0f,0f, 4f,2f,0f,1f)
        val target = BathroomScanGeometry(b)
        target.absorb(source, rotation)
        assertEquals(listOf(4.0, 2.0, -1.0, .75), target.pointSamples().single())
        assertEquals("unknown", target.planeSamples().single().toMap()["kind"])
        assertEquals(before, source.scene("2026-10-25T00:00:00.000Z", false))
        for (bad in listOf(identity().apply { this[0] = -1f }, identity(51f), identity().apply { this[12] = Float.NaN })) {
            assertThrows(IllegalArgumentException::class.java) { target.absorb(source, bad) }
        }
    }
    @Test fun `shared-frame assembly uses final anchor poses and preserves room bindings and source provenance`() {
        val input = HomeScanRequest.parse(request())!!
        var payload: Map<String, Any>? = null
        HomeScanAssembly.encode(input, listOf(HomeScanAssembly.Room(geometry(a), identity(), false),
            HomeScanAssembly.Room(geometry(b), identity(4f), true)), "2026-10-25T00:00:00.000Z") {
            if (it.containsKey("rooms")) payload = it
            json(it)
        }
        val rooms = payload!!["rooms"] as List<*>
        assertEquals(id, payload!!["sessionId"])
        val second = rooms.last() as Map<*, *>
        assertEquals(b, second["token"])
        val scene = second["scene"] as Map<*, *>
        assertEquals("arcore", scene["source"])
        assertEquals(b, scene["scanId"])
        assertEquals(listOf(5.0, 0.0, 0.0, .75), (scene["points"] as List<*>).single())
        val merged = payload!!["merged"] as Map<*, *>
        assertEquals(1, (merged["elements"] as List<*>).size)
        assertEquals(2, (merged["points"] as List<*>).size)
        assertEquals("partial", merged["coverage"])
    }
    @Test fun `eight dense rooms remain below Binder transport budget and disclose omissions`() {
        val input = HomeScanRequest.parse(request(List(8) { mapOf("token" to UUID.randomUUID().toString(), "name" to "Room $it") }))!!
        var payload: Map<String, Any>? = null
        val encoded = HomeScanAssembly.encode(input, input.rooms.mapIndexed { i, room ->
            HomeScanAssembly.Room(geometry(room.token, true), identity(i * 3f), false)
        }, "2026-10-25T00:00:00.000Z") {
            if (it.containsKey("rooms")) payload = it
            json(it)
        }
        assertTrue(encoded.toByteArray(Charsets.UTF_8).size <= HomeScanRequest.MAX_JSON_BYTES)
        assertTrue(encoded.toByteArray(Charsets.UTF_16LE).size < 1024 * 1024)
        val rooms = payload!!["rooms"] as List<*>
        assertEquals(8, rooms.size)
        assertTrue(rooms.sumOf { (((it as Map<*, *>)["scene"] as Map<*, *>)["points"] as List<*>).size } <= 8192)
        assertTrue(rooms.all { ((it as Map<*, *>)["scene"] as Map<*, *>)["truncated"] == true })
        assertEquals(true, (payload!!["merged"] as Map<*, *>)["truncated"])
    }
    @Test fun `crossed room bindings cannot be assembled into a plausible home`() {
        val input = HomeScanRequest.parse(request())!!
        assertThrows(IllegalArgumentException::class.java) {
            HomeScanAssembly.encode(input, listOf(HomeScanAssembly.Room(geometry(b), identity(), false),
                HomeScanAssembly.Room(geometry(a), identity(), false)), "2026-10-25T00:00:00.000Z", ::json)
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
