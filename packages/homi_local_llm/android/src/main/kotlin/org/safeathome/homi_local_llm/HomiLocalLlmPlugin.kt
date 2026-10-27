package org.safeathome.homi_local_llm

import android.app.Activity
import android.app.Application
import android.content.Context
import android.content.Intent
import android.os.Build
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.system.Os
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.embedding.engine.plugins.activity.ActivityAware
import io.flutter.embedding.engine.plugins.activity.ActivityPluginBinding
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.PluginRegistry
import java.io.File
import java.io.FileOutputStream
import java.security.MessageDigest
import java.util.UUID
import java.util.concurrent.Executors
import java.util.concurrent.atomic.AtomicBoolean

internal object LocalNative {
    init { System.loadLibrary("homi_llm") }
    external fun generate(id: ByteArray, path: ByteArray, system: ByteArray, prompt: ByteArray,
                          output: ByteArray, stats: DoubleArray): Int
    external fun cancel(id: ByteArray)
    external fun unload(): Int
}

class HomiLocalLlmPlugin : FlutterPlugin, MethodChannel.MethodCallHandler, ActivityAware,
    PluginRegistry.ActivityResultListener, Application.ActivityLifecycleCallbacks {
    private lateinit var context: Context
    private lateinit var channel: MethodChannel
    private val main = Handler(Looper.getMainLooper())
    private val worker = Executors.newSingleThreadExecutor()
    private val cancelled = AtomicBoolean(false)
    private val importCommitLock = Any()
    private var importId: String? = null
    private var activity: Activity? = null
    private var activityBinding: ActivityPluginBinding? = null
    private var activeId: String? = null
    private var reply: MethodChannel.Result? = null
    private var picking = false
    private var pickerCode: Int? = null
    private var nextPickerCode = 51803
    @Volatile private var foreground = false
    @Volatile private var attached = false
    private val compiled get() = BuildConfig.HOMI_LLAMA_TRIAL && Build.VERSION.SDK_INT >= 28 && Build.SUPPORTED_ABIS.contains("arm64-v8a")
    private val model get() = File(context.noBackupFilesDir, "HomiModels/Qwen3-0.6B-Q8_0.gguf")
    private fun status() = mapOf("compiled" to compiled, "installed" to (model.length() == MODEL_BYTES),
        "busy" to (activeId != null), "modelId" to "Qwen3-0.6B-Q8_0", "runtimeId" to RUNTIME,
        "bytes" to MODEL_BYTES, "sha256" to HASH)
    private fun error(result: MethodChannel.Result, code: String) = result.error(code, "The local model operation could not finish.", null)
    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        context = binding.applicationContext; attached = true
        channel = MethodChannel(binding.binaryMessenger, "homi_local_llm"); channel.setMethodCallHandler(this)
        (context as Application).registerActivityLifecycleCallbacks(this)
    }
    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        attached = false; detachActivity(); channel.setMethodCallHandler(null)
        (context as Application).unregisterActivityLifecycleCallbacks(this)
    }
    override fun onAttachedToActivity(binding: ActivityPluginBinding) {
        activityBinding = binding; activity = binding.activity; foreground = true; binding.addActivityResultListener(this)
    }
    override fun onReattachedToActivityForConfigChanges(binding: ActivityPluginBinding) = onAttachedToActivity(binding)
    override fun onDetachedFromActivityForConfigChanges() = detachActivity()
    override fun onDetachedFromActivity() = detachActivity()
    private fun detachActivity() {
        if (picking) { picking = false; pickerCode = null; activeId?.let { finish(it, null, "CANCELLED") } }
        stop(); activityBinding?.removeActivityResultListener(this); activityBinding = null; activity = null
    }
    private fun stop() {
        foreground = false
        if (picking) return // The system picker pauses our Activity; its result owns this operation.
        synchronized(importCommitLock) { cancelled.set(true) }
        activeId?.let { if (compiled) LocalNative.cancel(it.toByteArray(Charsets.UTF_8)) }
        if (compiled) worker.execute { LocalNative.unload() }
    }
    private fun finish(id: String, value: Any?, code: String? = null) {
        if (activeId != id) return
        val result = reply; activeId = null; reply = null
        if (result != null) { if (code == null) result.success(value) else error(result, code) }
    }
    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        val args = call.arguments as? Map<*, *>
        val id = (args?.get("requestId") as? String)?.takeIf { runCatching { UUID.fromString(it).toString().equals(it, true) }.getOrDefault(false) }
        when (call.method) {
            "status" -> { result.success(status()); return }
            "cancel" -> {
                if (id == null) { error(result, "INVALID_INPUT"); return }
                if (activeId == id) { synchronized(importCommitLock) { cancelled.set(true) }; if (compiled) LocalNative.cancel(id.toByteArray(Charsets.UTF_8))
                    if (picking) { picking = false; pickerCode = null; finish(id, null, "CANCELLED") } }
                result.success(null); return
            }
            "unload" -> {
                synchronized(importCommitLock) { cancelled.set(true) }; activeId?.let { if (compiled) LocalNative.cancel(it.toByteArray(Charsets.UTF_8)) }
                worker.execute { if (compiled) LocalNative.unload(); main.post { result.success(null) } }; return
            }
        }
        if (!compiled) { error(result, "UNSUPPORTED"); return }
        if (!foreground || !attached) { error(result, "CANCELLED"); return }
        if (activeId != null) { error(result, "BUSY"); return }
        if (call.method == "deleteModel") {
            val operation = UUID.randomUUID().toString(); activeId = operation; reply = result
            worker.execute {
                val success = runCatching { LocalNative.unload() == 0 && (!model.exists() || model.delete()) }.getOrDefault(false)
                main.post { activeId = null; reply = null; if (success) result.success(status()) else error(result, "FAILED") }
            }; return
        }
        if (id == null) { error(result, "INVALID_INPUT"); return }
        if (call.method == "importModel") {
            if (args?.keys != setOf("requestId") || activity == null) { error(result, "INVALID_INPUT"); return }
            activeId = id; reply = result; picking = true
            synchronized(importCommitLock) { cancelled.set(false); importId = id }
            val requestCode = nextPickerCode
            nextPickerCode = if (nextPickerCode >= 60000) 51803 else nextPickerCode + 1
            pickerCode = requestCode
            try { activity!!.startActivityForResult(Intent(Intent.ACTION_OPEN_DOCUMENT).apply {
                type = "application/octet-stream"; addCategory(Intent.CATEGORY_OPENABLE)
                putExtra(Intent.EXTRA_LOCAL_ONLY, true)
            }, requestCode) } catch (_: Exception) { picking = false; pickerCode = null; finish(id, null, "FAILED") }
            return
        }
        if (call.method != "generate") { result.notImplemented(); return }
        val system = args?.get("systemPrompt") as? String; val prompt = args?.get("prompt") as? String
        if (args?.keys != setOf("requestId", "systemPrompt", "prompt") || system == null || prompt == null ||
            system.toByteArray(Charsets.UTF_8).size + prompt.toByteArray(Charsets.UTF_8).size > 20000) { error(result, "INVALID_INPUT"); return }
        if (model.length() != MODEL_BYTES) { error(result, "MODEL_MISSING"); return }
        activeId = id; reply = result; cancelled.set(false)
        worker.execute {
            val output = ByteArray(9601); val stats = DoubleArray(4)
            val code = try { if (cancelled.get()) 3 else LocalNative.generate(id.toByteArray(Charsets.UTF_8), model.absolutePath.toByteArray(Charsets.UTF_8), system.toByteArray(Charsets.UTF_8), prompt.toByteArray(Charsets.UTF_8), output, stats) }
                catch (_: Throwable) { 7 }
            val end = output.indexOf(0).let { if (it < 0) output.size else it }
            val text = output.copyOfRange(0, end).toString(Charsets.UTF_8)
            main.post {
                val effective = if (!foreground || cancelled.get()) 3 else code
                if (effective == 0) finish(id, mapOf("text" to text, "firstTokenMs" to stats[0], "totalMs" to stats[1], "promptTokens" to stats[2].toInt(), "outputTokens" to stats[3].toInt()))
                else finish(id, null, codeName(effective))
            }
        }
    }
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?): Boolean {
        if (requestCode != pickerCode) return false
        if (!picking) return true
        picking = false; pickerCode = null; foreground = true
        val id = activeId ?: return true; val uri = data?.data
        if (resultCode != Activity.RESULT_OK || uri == null) { finish(id, null, "CANCELLED"); return true }
        worker.execute {
            val temporary = File(model.parentFile, "$id.part")
            val success = runCatching {
                model.parentFile!!.mkdirs()
                model.parentFile!!.listFiles()?.filter { it.name.endsWith(".part") }?.forEach { it.delete() }
                var count = 0L; val digest = MessageDigest.getInstance("SHA-256")
                context.contentResolver.openInputStream(uri).use { input ->
                    require(input != null)
                    FileOutputStream(temporary).use { output ->
                        val buffer = ByteArray(65536)
                        while (true) {
                            check(!cancelled.get())
                            val n = input.read(buffer); if (n < 0) break
                            count += n; require(count <= MODEL_BYTES)
                            digest.update(buffer, 0, n); output.write(buffer, 0, n)
                        }
                        output.fd.sync()
                    }
                }
                require(count == MODEL_BYTES && digest.digest().joinToString("") { "%02x".format(it) } == HASH)
                synchronized(importCommitLock) {
                    check(!cancelled.get() && foreground && attached && importId == id)
                    check(LocalNative.unload() == 0)
                    Os.rename(temporary.absolutePath, model.absolutePath)
                }
                true
            }.getOrDefault(false)
            temporary.delete()
            main.post { val result = reply; if (activeId == id) { activeId = null; reply = null
                if (result != null) { if (success) result.success(status()) else error(result, if (cancelled.get()) "CANCELLED" else "INVALID_MODEL") } } }
        }
        return true
    }
    override fun onActivityResumed(activity: Activity) { if (this.activity == activity) foreground = true }
    override fun onActivityPaused(activity: Activity) { if (this.activity == activity) stop() }
    override fun onActivityCreated(activity: Activity, state: Bundle?) {}
    override fun onActivityStarted(activity: Activity) {}
    override fun onActivityStopped(activity: Activity) {}
    override fun onActivitySaveInstanceState(activity: Activity, state: Bundle) {}
    override fun onActivityDestroyed(activity: Activity) { if (this.activity == activity) stop() }
    companion object {
        private const val MODEL_BYTES = 639446688L
        private const val HASH = "9465e63a22add5354d9bb4b99e90117043c7124007664907259bd16d043bb031"
        private const val RUNTIME = "llama.cpp:b11889:d854d98bae598388ecea1ed84396587e5edc326d"
        private fun codeName(code: Int) = when(code) { 1 -> "INVALID_INPUT"; 2 -> "BUSY"; 3 -> "CANCELLED"; 4 -> "MODEL_MISSING"; 5 -> "INVALID_MODEL"; 6 -> "CONTEXT_LIMIT"; 8 -> "UNSUPPORTED"; else -> "FAILED" }
    }
}
