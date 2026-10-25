package com.example.safe_at_home

import android.app.Activity
import android.os.Build
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.TimeoutCancellationException
import kotlinx.coroutines.cancel
import kotlinx.coroutines.launch
import kotlinx.coroutines.withTimeout

class PlanAssistantPlatform(private val activity: Activity, messenger: BinaryMessenger) {
    private val channel = MethodChannel(messenger, "safe_at_home/assistant")
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)
    private var backend: PlanAssistantBackend? = null
    private var foreground = false
    private var detached = false
    private var activeId: String? = null
    private var active: Job? = null
    private var reply: MethodChannel.Result? = null
    private val checks = mutableMapOf<Job, MethodChannel.Result>()

    private fun engine(): PlanAssistantBackend {
        if (Build.VERSION.SDK_INT < 26) throw AssistantNativeFailure("UNAVAILABLE")
        return backend ?: AICoreAssistantBackend(activity.applicationContext).also { backend = it }
    }
    fun register() {
        channel.setMethodCallHandler { call, result ->
            if (detached) { result.error("UNAVAILABLE", "On-device chat is unavailable.", null); return@setMethodCallHandler }
            when (call.method) {
                "availability" -> {
                    val args = call.arguments as? Map<*, *>
                    val locale = args?.get("locale") as? String
                    if (args?.keys != setOf("locale") || locale !in PlanAssistantRequest.locales) {
                        result.success("unsupportedLanguage")
                    } else if (Build.VERSION.SDK_INT < 26) {
                        result.success("requiresAndroid26")
                    } else if (!foreground) {
                        result.success("unavailable")
                    } else {
                        lateinit var job: Job
                        job = scope.launch(start = kotlinx.coroutines.CoroutineStart.LAZY) {
                            val status = try { withTimeout(6_000) { engine().status(locale!!) } }
                            catch (_: Exception) { "unavailable" }
                            catch (_: LinkageError) { "unavailable" }
                            checks.remove(job)?.success(if (foreground && !detached) status else "unavailable")
                        }
                        checks[job] = result; job.start()
                    }
                }
                "respond", "download" -> {
                    val request = if (call.method == "respond") PlanAssistantRequest.parse(call.arguments) else null
                    val id = request?.requestId ?: if (call.method == "download") PlanAssistantRequest.requestId(call.arguments) else null
                    if (id == null) { result.error("INVALID_INPUT", "The chat request is invalid.", null) }
                    else if (activeId != null) { result.error("BUSY", "Finish the current chat request.", null) }
                    else if (Build.VERSION.SDK_INT < 26 || !foreground) { result.error("UNAVAILABLE", "On-device chat is unavailable.", null) }
                    else {
                        activeId = id; reply = result
                        active = scope.launch {
                            try {
                                val response = withTimeout(if (request == null) 180_000L else 55_000L) {
                                    if (request == null) { engine().download(); null } else engine().respond(request)
                                }
                                finish(id, response, null)
                            } catch (_: TimeoutCancellationException) { finish(id, null, "TIMEOUT") }
                            catch (_: CancellationException) { finish(id, null, "CANCELLED") }
                            catch (e: AssistantNativeFailure) { finish(id, null, e.code) }
                            catch (_: Exception) { finish(id, null, "FAILED") }
                            catch (_: LinkageError) { finish(id, null, "UNAVAILABLE") }
                        }
                    }
                }
                "cancel" -> {
                    val id = PlanAssistantRequest.requestId(call.arguments)
                    if (id == null) result.error("INVALID_INPUT", "The chat request is invalid.", null)
                    else { if (activeId == id) cancelActive(); result.success(null) }
                }
                else -> result.notImplemented()
            }
        }
    }
    private fun finish(id: String, text: String?, code: String?) {
        if (activeId != id) return
        val result = reply
        activeId = null; reply = null; active = null
        if (code == null && foreground && !detached) result?.success(text)
        else result?.error(code ?: "CANCELLED", "The chat request could not finish.", null)
    }
    private fun cancelActive() {
        val id = activeId ?: return
        val job = active
        finish(id, null, "CANCELLED"); job?.cancel()
    }
    fun onResume() { foreground = true }
    fun onPause() {
        foreground = false; cancelActive()
        val pending = checks.toMap(); checks.clear()
        pending.forEach { (job, result) -> job.cancel(); result.success("unavailable") }
        try { backend?.close() } catch (_: Exception) {   }
        catch (_: LinkageError) {   }
        backend = null
    }
    fun detach() {
        onPause(); detached = true; channel.setMethodCallHandler(null); scope.cancel()
    }
}

internal class AssistantNativeFailure(val code: String) : Exception()
internal interface PlanAssistantBackend {
    suspend fun status(locale: String): String
    suspend fun respond(request: PlanAssistantRequest): String
    suspend fun download()
    fun close()
}
