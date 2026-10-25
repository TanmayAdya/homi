package com.example.safe_at_home

import android.Manifest
import android.content.ComponentCallbacks2
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.graphics.Color
import android.opengl.GLSurfaceView
import android.os.Bundle
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.os.PowerManager
import android.os.SystemClock
import android.text.SpannableString
import android.text.Spanned
import android.text.method.LinkMovementMethod
import android.text.style.URLSpan
import android.view.Gravity
import android.view.View
import android.view.WindowManager
import android.widget.Button
import android.widget.LinearLayout
import android.widget.ScrollView
import android.widget.TextView
import androidx.activity.ComponentActivity
import androidx.activity.OnBackPressedCallback
import com.google.ar.core.ArCoreApk
import com.google.ar.core.Config
import com.google.ar.core.Session
import com.google.ar.core.exceptions.UnavailableException
import org.json.JSONObject
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale
import java.util.TimeZone
import java.util.concurrent.atomic.AtomicBoolean

class BathroomScanActivity : ComponentActivity() {
    private val handler = Handler(Looper.getMainLooper())
    private val availability by lazy { bathroomScanAvailabilityLookup(this, handler) }
    private var session: Session? = null
    private var surface: GLSurfaceView? = null
    private var renderer: BathroomScanRenderer? = null
    private var status: TextView? = null
    private var reviewButton: Button? = null
    private var scanId: String = ""
    private var languageCode: String = "en"
    private var roomName: String? = null
    private var home: HomeScanRequest? = null
    private var homeBetweenRooms = false
    private var homeFinishing = false
    private var homeRoomIndex = 0
    private var heading: TextView? = null
    private var phaseStartedAt = 0L
    private val phaseTimeout = Runnable { fail("scan_limit") }
    private var startRequested = false
    private var checkingAvailability = false
    private var availabilityConfirmed = false
    private var permissionRequested = false
    private var installRequested = false
    private var resumed = false
    private var active = false
    @Volatile private var completed = false
    private var startedAt = 0L
    private var depthSupported = false
    private var ownsSessionSlot = false
    private var thermalListener: PowerManager.OnThermalStatusChangedListener? = null
    private val timeout = Runnable { fail("scan_limit") }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        window.addFlags(WindowManager.LayoutParams.FLAG_SECURE)
        scanId = intent.getStringExtra(BathroomScanPlatform.EXTRA_SCAN_ID) ?: ""
        languageCode = intent.getStringExtra(BathroomScanPlatform.EXTRA_LANGUAGE) ?: "en"
        roomName = intent.getStringExtra(BathroomScanPlatform.EXTRA_ROOM_NAME)
        if (intent.getBooleanExtra(BathroomScanPlatform.EXTRA_HOME, false)) {
            val tokens = intent.getStringArrayListExtra(BathroomScanPlatform.EXTRA_ROOM_TOKENS)
            val names = intent.getStringArrayListExtra(BathroomScanPlatform.EXTRA_ROOM_NAMES)
            if (tokens == null || names == null || tokens.size != names.size) { fail("scan_failed"); return }
            home = HomeScanRequest.parse(mapOf("scanId" to scanId, "languageCode" to languageCode,
                "rooms" to tokens.indices.map { mapOf("token" to tokens[it], "name" to names[it]) }))
            if (home == null) { fail("scan_failed"); return }
        }
        if (!BathroomScanGeometry.isScanId(scanId) || savedInstanceState != null) {
            fail("scan_interrupted")
            return
        }
        onBackPressedDispatcher.addCallback(this, object : OnBackPressedCallback(true) {
            override fun handleOnBackPressed() { fail("scan_cancelled") }
        })
        showNotice()
    }

    private fun showNotice() {
        val column = column()
        column.addView(text(if (home == null) "Scan this room" else "Room scan", 26f))
        if (home == null) roomName?.let { name -> column.addView(text("", 22f).apply { text = name }) }
        column.addView(text("Move slowly from a safe position. Keep the camera facing walls, floor and fixtures. Do not walk backward or step over obstacles while looking at the screen.", 18f))
        column.addView(text("This captures an approximate arrangement of surfaces and points. Android does not automatically identify toilets, sinks or doors. You will review the model and identify what it shows.", 18f))
        column.addView(text(if (home == null)
            "Safe at Home does not save or upload raw camera frames. The reviewed geometry stays in your encrypted case on this device. Backgrounding or exceeding three minutes cancels this scan."
            else "Geometry stays private on this device. Backgrounding cancels the entire connected capture. Stay on one level; review room positions before saving.", 16f))
        if (home != null) column.addView(text("Scan only the named room. Keep the phone tracking while moving between rooms. Stay on one level and a safe, clear path.", 18f))
        val notice = text("This application runs on Google Play Services for AR (ARCore), which is provided by Google and governed by the Google Privacy Policy.", 16f)
        val linked = SpannableString(notice.text)
        val playLabel = "Google Play Services for AR"
        val policyLabel = "Google Privacy Policy"
        val playStart = linked.toString().indexOf(playLabel)
        val policyStart = linked.toString().indexOf(policyLabel)
        linked.setSpan(URLSpan("https://play.google.com/store/apps/details?id=com.google.ar.core"), playStart, playStart + playLabel.length, Spanned.SPAN_EXCLUSIVE_EXCLUSIVE)
        linked.setSpan(URLSpan("https://policies.google.com/privacy"), policyStart, policyStart + policyLabel.length, Spanned.SPAN_EXCLUSIVE_EXCLUSIVE)
        notice.text = linked
        notice.movementMethod = LinkMovementMethod.getInstance()
        notice.setLinkTextColor(Color.rgb(22, 94, 86))
        column.addView(notice)
        column.addView(button("Start room scan") {
            if (!startRequested) {
                startRequested = true
                startIfReady()
            }
        })
        column.addView(button("Cancel") { fail("scan_cancelled") })
        setContentView(ScrollView(this).apply { isFillViewport = true; addView(column) })
    }

    override fun onResume() {
        super.onResume()
        resumed = true
        if (startRequested && !completed && session == null) startIfReady()
    }

    private fun startIfReady() {
        if (!resumed || completed || active) return
        if (!availabilityConfirmed) {
            if (checkingAvailability) return
            checkingAvailability = true
            availability.check { result ->
                checkingAvailability = false
                if (!completed) {
                    if (result?.isSupported == true) {
                        availabilityConfirmed = true
                        startIfReady()
                    } else {
                        fail("scan_unavailable")
                    }
                }
            }
            return
        }
        if (checkSelfPermission(Manifest.permission.CAMERA) != PackageManager.PERMISSION_GRANTED) {
            if (permissionRequested) return
            permissionRequested = true
            requestPermissions(arrayOf(Manifest.permission.CAMERA), CAMERA_PERMISSION)
            return
        }
        try {
            when (ArCoreApk.getInstance().requestInstall(
                this,
                !installRequested,
                ArCoreApk.InstallBehavior.OPTIONAL,
                ArCoreApk.UserMessageType.FEATURE,
            )) {
                ArCoreApk.InstallStatus.INSTALL_REQUESTED -> {
                    installRequested = true
                    return
                }
                ArCoreApk.InstallStatus.INSTALLED -> Unit
            }
            if (!sessionSlot.compareAndSet(false, true)) {
                fail("scan_busy")
                return
            }
            ownsSessionSlot = true
            val created = Session(this)
            session = created
            depthSupported = created.isDepthModeSupported(Config.DepthMode.RAW_DEPTH_ONLY)
            created.configure(Config(created).apply {
                planeFindingMode = Config.PlaneFindingMode.HORIZONTAL_AND_VERTICAL
                depthMode = if (depthSupported) Config.DepthMode.RAW_DEPTH_ONLY else Config.DepthMode.DISABLED
                focusMode = Config.FocusMode.AUTO
                updateMode = Config.UpdateMode.LATEST_CAMERA_IMAGE
                lightEstimationMode = Config.LightEstimationMode.DISABLED
                cloudAnchorMode = Config.CloudAnchorMode.DISABLED
                geospatialMode = Config.GeospatialMode.DISABLED
            })
            created.resume()
            active = true
            startedAt = SystemClock.elapsedRealtime()
            if (!observeDevicePressure()) return
            window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
            showCamera(created)
            handler.postDelayed(timeout, if (home == null) MAX_CAPTURE_MS else 900_000L)
            if (home != null) setPhaseLimit(MAX_CAPTURE_MS)
        } catch (_: SecurityException) {
            fail("scan_permission_denied")
        } catch (_: UnavailableException) {
            fail("scan_unavailable")
        } catch (_: Exception) {
            fail("scan_failed")
        }
    }

    private fun showCamera(created: Session) {
        val column = BathroomScanCaptureLayout(this).apply {
            setBackgroundColor(Color.rgb(248, 246, 239))
            fitsSystemWindows = true
        }
        val scanRenderer = BathroomScanRenderer(created, BathroomScanGeometry(scanId), depthSupported,
            rotation = { windowManager.defaultDisplay.rotation },
            onProgress = { planes, points, tracking ->
                handler.post {
                    if (!completed && active) {
                        if (homeBetweenRooms || homeFinishing) return@post
                        val secondsLeft = ((MAX_CAPTURE_MS - (SystemClock.elapsedRealtime() - if (home == null) startedAt else phaseStartedAt)) / 1000).coerceAtLeast(0)
                        status?.text = if (tracking) {
                            scanText("{surfaces} surfaces · {points} sampled points · {seconds}s remaining. Move slowly. Missing areas stay unknown.",
                                mapOf("surfaces" to planes.toString(), "points" to points.toString(), "seconds" to secondsLeft.toString()))
                        } else {
                            scanText("Finding position. Move slowly in good light and avoid blank or reflective surfaces. {seconds}s remaining.",
                                mapOf("seconds" to secondsLeft.toString()))
                        }
                        reviewButton?.isEnabled = (home == null || tracking) && (planes > 0 || points >= 20)
                    }
                }
            },
            onFailure = { handler.post { fail("scan_failed") } },
            home = home?.let { HomeScanCollector(created, it) },
        )
        renderer = scanRenderer
        val cameraView = GLSurfaceView(this).apply {
            setEGLContextClientVersion(2)
            preserveEGLContextOnPause = false
            contentDescription = scanText("Live room camera view. Detected surfaces and sampled points are outlined.")
            setRenderer(scanRenderer)
            renderMode = GLSurfaceView.RENDERMODE_CONTINUOUSLY
        }
        surface = cameraView
        column.addView(cameraView, LinearLayout.LayoutParams(LinearLayout.LayoutParams.MATCH_PARENT, 0, 1f))
        val controls = column()
        heading = text("Room scan", 24f).also { title ->
            if (home == null) roomName?.let { title.text = "${title.text}\n$it" }
            controls.addView(title)
        }
        updateHomeHeading()
        status = text("Finding position. Move slowly while facing the room.", 16f)
        controls.addView(status)
        reviewButton = button(if (home == null) "Finish and review 3D scan" else "Finish this room") { finishScan() }.apply { isEnabled = false }
        controls.addView(reviewButton)
        controls.addView(button("Cancel scan") { fail("scan_cancelled") })
        val controlsScroll = ScrollView(this).apply { addView(controls) }
        column.controls = controlsScroll
        column.addView(controlsScroll, LinearLayout.LayoutParams(LinearLayout.LayoutParams.MATCH_PARENT, dp(280)))
        setContentView(column)
        cameraView.onResume()
    }

    private fun finishScan() {
        if (completed || !active) return
        if (home != null) { advanceHome(); return }
        if (SystemClock.elapsedRealtime() - startedAt >= MAX_CAPTURE_MS) {
            fail("scan_limit")
            return
        }
        completed = true
        stopCapture()
        try {
            val geometry = renderer?.geometry ?: error("missing geometry")
            require(geometry.elementCount > 0 || geometry.pointCount >= 20)
            val formatter = SimpleDateFormat("yyyy-MM-dd'T'HH:mm:ss.SSS'Z'", Locale.US).apply {
                timeZone = TimeZone.getTimeZone("UTC")
            }
            val scene = geometry.encodeSceneWithinLimit(formatter.format(Date()), renderer?.capturedDepth == true) {
                JSONObject(it).toString()
            }
            if (scene == null) {
                returnError("scan_limit")
                return
            }
            setResult(RESULT_OK, Intent().putExtra(BathroomScanPlatform.EXTRA_SCAN_ID, scanId).putExtra(BathroomScanPlatform.EXTRA_SCENE, scene))
            finish()
        } catch (_: Exception) {
            returnError("scan_failed")
        }
    }

    private fun updateHomeHeading() {
        val request = home ?: return
        heading?.text = "${homeRoomIndex + 1} / ${request.rooms.size} · ${request.rooms[homeRoomIndex].name}"
    }
    private fun setPhaseLimit(milliseconds: Long) {
        handler.removeCallbacks(phaseTimeout)
        phaseStartedAt = SystemClock.elapsedRealtime()
        handler.postDelayed(phaseTimeout, milliseconds)
    }
    private fun advanceHome() {
        val scanRenderer = renderer ?: return
        reviewButton?.isEnabled = false
        if (homeBetweenRooms) {
            homeBetweenRooms = false
            surface?.queueEvent { if (!completed) scanRenderer.startNextRoom() }
            reviewButton?.text = scanText("Finish this room")
            setPhaseLimit(MAX_CAPTURE_MS)
            updateHomeHeading()
            return
        }
        if (homeFinishing) return
        homeFinishing = true
        surface?.queueEvent {
            if (!completed) scanRenderer.requestHomeFinish { step ->
                handler.post {
                    if (!completed) {
                        homeFinishing = false
                        if (step.retry) {
                            status?.text = scanText("Tracking is limited. Hold the phone steady in a well-lit area before finishing.")
                            reviewButton?.isEnabled = true
                        } else if (step.payload != null) {
                            completed = true
                            stopCapture()
                            setResult(RESULT_OK, Intent().putExtra(BathroomScanPlatform.EXTRA_SCAN_ID, scanId)
                                .putExtra(BathroomScanPlatform.EXTRA_SCENE, step.payload))
                            finish()
                        } else {
                            homeBetweenRooms = true
                            homeRoomIndex = step.finishedRooms
                            updateHomeHeading()
                            status?.text = scanText("Keep the camera tracking. Move safely to the next named room, then start it. Cancelling retains your earlier saved models.")
                            reviewButton?.text = scanText("Start next room")
                            reviewButton?.isEnabled = true
                            setPhaseLimit(120_000L)
                        }
                    }
                }
            }
        }
    }

    private fun fail(code: String) {
        if (completed) return
        completed = true
        stopCapture()
        returnError(code)
    }

    private fun returnError(code: String) {
        setResult(RESULT_CANCELED, Intent().putExtra(BathroomScanPlatform.EXTRA_SCAN_ID, scanId).putExtra(BathroomScanPlatform.EXTRA_ERROR, code))
        finish()
    }

    private fun stopCapture() {
        handler.removeCallbacks(timeout)
        handler.removeCallbacks(phaseTimeout)
        if (Build.VERSION.SDK_INT >= 29) {
            thermalListener?.let {
                try { getSystemService(PowerManager::class.java)?.removeThermalStatusListener(it) } catch (_: Exception) { }
            }
            thermalListener = null
        }
        surface?.onPause()
        if (active) {
            active = false
            try { session?.pause() } catch (_: Exception) {   }
        }
        window.clearFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
    }

    private fun observeDevicePressure(): Boolean {
        if (Build.VERSION.SDK_INT < 29) return true
        try {
            val power = getSystemService(PowerManager::class.java) ?: return true
            if (power.currentThermalStatus >= PowerManager.THERMAL_STATUS_SEVERE) {
                fail("scan_limit")
                return false
            }
            val listener = PowerManager.OnThermalStatusChangedListener { status ->
                if (active && !completed && status >= PowerManager.THERMAL_STATUS_SEVERE) fail("scan_limit")
            }
            power.addThermalStatusListener(listener)
            thermalListener = listener
        } catch (_: Exception) {
        }
        return true
    }

    @Suppress("DEPRECATION")
    override fun onTrimMemory(level: Int) {
        super.onTrimMemory(level)
        if (active && !completed && level >= ComponentCallbacks2.TRIM_MEMORY_RUNNING_CRITICAL) fail("scan_limit")
    }

    override fun onPause() {
        resumed = false
        if (active && !completed) fail("scan_interrupted") else stopCapture()
        super.onPause()
    }

    override fun onDestroy() {
        completed = true
        availability.close()
        stopCapture()
        try { renderer?.closeHome() } catch (_: Exception) {   }
        renderer = null
        surface = null
        handler.removeCallbacksAndMessages(null)
        val closing = session
        session = null
        if (ownsSessionSlot) {
            ownsSessionSlot = false
            if (closing == null) {
                sessionSlot.set(false)
            } else {
                Thread({
                    try { closing.close() } catch (_: Exception) {
                    } finally { sessionSlot.set(false) }
                }, "bathroom-scan-release").start()
            }
        }
        super.onDestroy()
    }

    override fun onRequestPermissionsResult(requestCode: Int, permissions: Array<String>, grantResults: IntArray) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        if (requestCode != CAMERA_PERMISSION || completed) return
        if (grantResults.firstOrNull() == PackageManager.PERMISSION_GRANTED) startIfReady()
        else fail("scan_permission_denied")
    }

    private fun column() = LinearLayout(this).apply {
        orientation = LinearLayout.VERTICAL
        setPadding(dp(20), dp(16), dp(20), dp(16))
        setBackgroundColor(Color.rgb(248, 246, 239))
    }
    private fun text(value: String, size: Float) = TextView(this).apply {
        text = scanText(value)
        textSize = size
        setTextColor(Color.rgb(23, 55, 51))
        setPadding(dp(8), dp(10), dp(8), dp(10))
    }
    private fun button(label: String, action: () -> Unit) = Button(this).apply {
        text = scanText(label)
        isAllCaps = false
        minHeight = dp(52)
        gravity = Gravity.CENTER
        setOnClickListener { action() }
        layoutParams = LinearLayout.LayoutParams(LinearLayout.LayoutParams.MATCH_PARENT, LinearLayout.LayoutParams.WRAP_CONTENT)
    }
    private fun dp(value: Int) = (value * resources.displayMetrics.density).toInt()

    private fun scanText(english: String, arguments: Map<String, String> = emptyMap()): String =
        Regex("\\{([A-Za-z][A-Za-z0-9_]*)\\}").replace(AppScanTranslations.text(english, languageCode)) { match ->
            arguments[match.groupValues[1]] ?: match.value
        }

    companion object {
        private const val CAMERA_PERMISSION = 21315
        private const val MAX_CAPTURE_MS = 180_000L
        private val sessionSlot = AtomicBoolean(false)
    }
}

private class BathroomScanCaptureLayout(context: Context) : LinearLayout(context) {
    var controls: View? = null
    init { orientation = VERTICAL }

    override fun onMeasure(widthMeasureSpec: Int, heightMeasureSpec: Int) {
        if (MeasureSpec.getMode(heightMeasureSpec) != MeasureSpec.UNSPECIFIED) {
            controls?.layoutParams?.height = bathroomScanControlsHeight(
                MeasureSpec.getSize(heightMeasureSpec) - paddingTop - paddingBottom,
                (280 * resources.displayMetrics.density).toInt(),
            )
        }
        super.onMeasure(widthMeasureSpec, heightMeasureSpec)
    }
}

internal fun bathroomScanControlsHeight(availableHeight: Int, preferredHeight: Int): Int =
    minOf(preferredHeight.coerceAtLeast(0), availableHeight.coerceAtLeast(0) / 2)
