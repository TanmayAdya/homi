package com.example.safe_at_home

internal data class PlanAssistantRequest(
    val requestId: String, val locale: String, val question: String,
    val history: String, val findings: String,
    val appContext: String? = null, val guide: String? = null,
) {
    companion object {
        val locales = setOf("en", "es", "zh-Hans", "zh-Hant", "vi", "fil")
        fun parse(value: Any?): PlanAssistantRequest? {
            val v = value as? Map<*, *> ?: return null
            val legacyKeys = setOf("requestId", "locale", "question", "history", "findings")
            val contextual = v.keys == legacyKeys + setOf("appContext", "guide")
            if (v.keys != legacyKeys && !contextual) return null
            val id = requestId(mapOf("requestId" to v["requestId"])) ?: return null
            val locale = v["locale"] as? String ?: return null
            val question = v["question"] as? String ?: return null
            val history = v["history"] as? String ?: return null
            val findings = v["findings"] as? String ?: return null
            if (locale !in locales || question.isBlank() ||
                !boundedText(question, 600) || !boundedText(history, 2400) || !boundedText(findings, 2400) ||
                question.toByteArray(Charsets.UTF_8).size + history.toByteArray(Charsets.UTF_8).size +
                    findings.toByteArray(Charsets.UTF_8).size > 10_000) return null
            val appContext = if (contextual) v["appContext"] as? String ?: return null else null
            val guide = if (contextual) v["guide"] as? String ?: return null else null
            if (contextual && (appContext!!.isBlank() || guide!!.isBlank() ||
                    !boundedText(appContext, 16384) || !boundedText(guide, 8192) ||
                    appContext.toByteArray(Charsets.UTF_8).size > 16384 ||
                    guide.toByteArray(Charsets.UTF_8).size > 8192)) return null
            return PlanAssistantRequest(id, locale, question, history, findings, appContext, guide)
        }
        fun requestId(value: Any?): String? {
            val v = value as? Map<*, *> ?: return null
            if (v.keys != setOf("requestId")) return null
            return (v["requestId"] as? String)?.takeIf(BathroomScanGeometry::isScanId)
        }
        fun acceptsContextReply(value: Map<String, Any?>, allowedSources: Set<String>): Boolean {
            if (!value.keys.containsAll(setOf("text", "sourceIds")) ||
                !setOf("text", "sourceIds", "openSourceId").containsAll(value.keys)) return false
            val text = value["text"] as? String ?: return false
            val sources = value["sourceIds"] as? List<*> ?: return false
            val open = value["openSourceId"]
            return text.isNotBlank() && boundedText(text, 1200) &&
                text.none { it.code in 0..8 || it.code in 11..12 || it.code in 14..31 || it.code == 127 } &&
                sources.size <= 6 && sources.toSet().size == sources.size &&
                sources.all { it is String && it in allowedSources } &&
                (open == null || open is String && open in sources)
        }
        private fun boundedText(value: String, max: Int): Boolean {
            if (value.codePointCount(0, value.length) > max) return false
            var index = 0
            while (index < value.length) {
                val ch = value[index++]
                if (ch.isHighSurrogate()) {
                    if (index >= value.length || !value[index++].isLowSurrogate()) return false
                } else if (ch.isLowSurrogate()) return false
            }
            return true
        }
    }
}
