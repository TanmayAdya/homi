package com.example.safe_at_home

import android.content.Context
import androidx.annotation.RequiresApi
import com.google.mlkit.common.MlKit
import com.google.mlkit.genai.common.DownloadStatus
import com.google.mlkit.genai.common.FeatureStatus
import com.google.mlkit.genai.common.GenAiException
import com.google.mlkit.genai.prompt.Candidate
import com.google.mlkit.genai.prompt.Generation
import com.google.mlkit.genai.prompt.SystemInstruction
import com.google.mlkit.genai.prompt.TextPart
import com.google.mlkit.genai.prompt.generateContentRequest
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.flow.collect
import org.json.JSONObject

@RequiresApi(26)
internal class AICoreAssistantBackend(context: Context) : PlanAssistantBackend {
    init { MlKit.initialize(context) }
    private val model = Generation.getClient()
    override suspend fun status(locale: String): String {
        if (locale !in PlanAssistantRequest.locales) return "unsupportedLanguage"
        return when (model.checkStatus()) {
            FeatureStatus.AVAILABLE -> "ready"
            FeatureStatus.DOWNLOADABLE -> "modelDownloadable"
            FeatureStatus.DOWNLOADING -> "modelDownloading"
            else -> "unavailable"
        }
    }
    override suspend fun download() {
        try {
            when (model.checkStatus()) {
                FeatureStatus.AVAILABLE -> return
                FeatureStatus.DOWNLOADABLE -> Unit
                FeatureStatus.DOWNLOADING -> throw AssistantNativeFailure("BUSY")
                else -> throw AssistantNativeFailure("UNAVAILABLE")
            }
            var complete = false
            model.download().collect { status ->
                currentCoroutineContext().ensureActive()
                when (status) {
                    DownloadStatus.DownloadCompleted -> complete = true
                    is DownloadStatus.DownloadFailed -> throw status.e
                    else -> Unit
                }
            }
            if (!complete || model.checkStatus() != FeatureStatus.AVAILABLE) throw AssistantNativeFailure("UNAVAILABLE")
        } catch (e: GenAiException) { throw AssistantNativeFailure(errorCode(e.errorCode)) }
    }
    override suspend fun respond(request: PlanAssistantRequest): String {
        try {
            if (status(request.locale) != "ready") throw AssistantNativeFailure("UNAVAILABLE")
            val sourceIds = request.appContext?.let { context ->
                try {
                    val objectValue = JSONObject(context)
                    require(objectValue.keys().asSequence().toSet() == setOf("version", "destination", "state", "sources"))
                    require(objectValue.getInt("version") == 2)
                    require(objectValue.getString("destination") in setOf("plan", "rooms", "help", "tasks", "settings"))
                    objectValue.getJSONObject("state")
                    val sources = objectValue.getJSONArray("sources")
                    require(sources.length() <= 32)
                    val ids = (0 until sources.length()).map { sources.getJSONObject(it).getString("id") }
                    require(ids.all { it.isNotBlank() && it.length <= 80 } && ids.toSet().size == ids.size)
                    ids.toSet()
                } catch (_: Exception) { throw AssistantNativeFailure("INVALID_INPUT") }
            }
            val data = JSONObject(mapOf(
                "requestedLanguage" to request.locale,
                "residentQuestion" to request.question,
                "untrustedRecentConversation" to request.history,
                "untrustedConfirmedFindingExcerpts" to request.findings,
            ) + (request.appContext?.let { mapOf("currentAppContext" to it) } ?: emptyMap())).toString()
            val instructions = planAssistantInstructionsFor(request)
            val outputTokens = if (request.appContext == null) 384 else 768
            val hasSystem = model.isSystemPromptAvailable()
            val input = if (hasSystem) data else "$instructions\nUNTRUSTED RESIDENT DATA (JSON):\n$data"
            val content = generateContentRequest(TextPart(input)) {
                if (hasSystem) systemInstruction = SystemInstruction(instructions)
                temperature = 0.2f
                maxOutputTokens = outputTokens
                candidateCount = 1
                enableThinking = false
            }
            val tokens = model.countTokens(content).totalTokens
            if (tokens <= 0 || tokens + outputTokens > model.getTokenLimit()) throw AssistantNativeFailure("CONTEXT_LIMIT")
            currentCoroutineContext().ensureActive()
            val response = model.generateContent(content)
            currentCoroutineContext().ensureActive()
            val candidate = response.candidates.firstOrNull() ?: throw AssistantNativeFailure("REFUSED")
            if (candidate.finishReason == Candidate.FinishReason.MAX_TOKENS) throw AssistantNativeFailure("CONTEXT_LIMIT")
            val text = candidate.text.trim()
            if (text.isEmpty() || text.codePointCount(0, text.length) > (if (request.appContext == null) 2400 else 8192)) throw AssistantNativeFailure("INVALID_RESPONSE")
            if (sourceIds != null) {
                val valid = try {
                    require(text.toByteArray(Charsets.UTF_8).size <= 8192)
                    val result = JSONObject(text)
                    val values = result.keys().asSequence().associateWith { key ->
                        when (key) {
                            "sourceIds" -> result.getJSONArray(key).let { array -> (0 until array.length()).map { array.get(it) } }
                            else -> result.get(key).takeUnless { it == JSONObject.NULL }
                        }
                    }
                    PlanAssistantRequest.acceptsContextReply(values, sourceIds)
                } catch (_: Exception) { false }
                if (!valid) throw AssistantNativeFailure("INVALID_RESPONSE")
            }
            return text
        } catch (e: GenAiException) { throw AssistantNativeFailure(errorCode(e.errorCode)) }
    }
    override fun close() { model.close() }

    private fun errorCode(code: Int): String = when (code) {
        GenAiException.ErrorCode.CANCELLED, GenAiException.ErrorCode.BACKGROUND_USE_BLOCKED -> "CANCELLED"
        GenAiException.ErrorCode.BUSY, GenAiException.ErrorCode.PER_APP_BATTERY_USE_QUOTA_EXCEEDED -> "BUSY"
        GenAiException.ErrorCode.REQUEST_TOO_LARGE, GenAiException.ErrorCode.REQUEST_TOO_SMALL -> "CONTEXT_LIMIT"
        GenAiException.ErrorCode.NOT_AVAILABLE, GenAiException.ErrorCode.NOT_SUPPORTED,
        GenAiException.ErrorCode.NEEDS_SYSTEM_UPDATE, GenAiException.ErrorCode.AICORE_INCOMPATIBLE -> "UNAVAILABLE"
        GenAiException.ErrorCode.NOT_ENOUGH_DISK_SPACE -> "STORAGE"
        else -> "FAILED"
    }
}
