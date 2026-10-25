package com.example.safe_at_home

import android.opengl.GLES11Ext
import android.opengl.GLES20
import android.opengl.GLSurfaceView
import android.opengl.Matrix
import android.os.SystemClock
import com.google.ar.core.Coordinates2d
import com.google.ar.core.Frame
import com.google.ar.core.Plane
import com.google.ar.core.Session
import com.google.ar.core.TrackingState
import com.google.ar.core.exceptions.NotYetAvailableException
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.nio.FloatBuffer
import java.util.UUID
import javax.microedition.khronos.egl.EGLConfig
import javax.microedition.khronos.opengles.GL10
import kotlin.math.ceil
import kotlin.math.sqrt

internal class BathroomScanRenderer(
    private val session: Session,
    private val singleGeometry: BathroomScanGeometry,
    private val depthSupported: Boolean,
    private val rotation: () -> Int,
    private val onProgress: (Int, Int, Boolean) -> Unit,
    private val onFailure: () -> Unit,
    private val home: HomeScanCollector? = null,
) : GLSurfaceView.Renderer {
    val geometry: BathroomScanGeometry get() = home?.geometry ?: singleGeometry
    private var texture = 0
    private var textureAssigned = false
    private var backgroundProgram = 0
    private var geometryProgram = 0
    private var width = 1
    private var height = 1
    private var lastRotation = -1
    private var displayDirty = true
    private var failed = false
    private var lastSampleTime = 0L
    private var lastFrameTimestamp = -1L
    private var lastDepthTimestamp = -1L
    private val planeIds = linkedMapOf<Plane, String>()
    private val homePlaneIds = linkedMapOf<Plane, String>()
    private val quad = direct(floatArrayOf(-1f, -1f, 1f, -1f, -1f, 1f, 1f, 1f))
    private val textureCoordinates = direct(FloatArray(8))
    private val projection = FloatArray(16)
    private val view = FloatArray(16)
    private val viewProjection = FloatArray(16)
    private val pointVertices = direct(FloatArray(BathroomScanGeometry.MAX_POINTS * 3))
    private val lineVertices = direct(FloatArray(BathroomScanGeometry.MAX_ELEMENTS * 8 * 3))
    private var renderedPoints = 0
    private var renderedLines = 0
    var capturedDepth = false
        private set

    override fun onSurfaceCreated(gl: GL10?, config: EGLConfig?) {
        try {
            val names = IntArray(1)
            GLES20.glGenTextures(1, names, 0)
            texture = names[0]
            GLES20.glBindTexture(GLES11Ext.GL_TEXTURE_EXTERNAL_OES, texture)
            GLES20.glTexParameteri(GLES11Ext.GL_TEXTURE_EXTERNAL_OES, GLES20.GL_TEXTURE_MIN_FILTER, GLES20.GL_LINEAR)
            GLES20.glTexParameteri(GLES11Ext.GL_TEXTURE_EXTERNAL_OES, GLES20.GL_TEXTURE_MAG_FILTER, GLES20.GL_LINEAR)
            GLES20.glTexParameteri(GLES11Ext.GL_TEXTURE_EXTERNAL_OES, GLES20.GL_TEXTURE_WRAP_S, GLES20.GL_CLAMP_TO_EDGE)
            GLES20.glTexParameteri(GLES11Ext.GL_TEXTURE_EXTERNAL_OES, GLES20.GL_TEXTURE_WRAP_T, GLES20.GL_CLAMP_TO_EDGE)
            backgroundProgram = program(
                "attribute vec2 position; attribute vec2 uv; varying vec2 imageUV; void main(){gl_Position=vec4(position,0.0,1.0);imageUV=uv;}",
                "#extension GL_OES_EGL_image_external : require\nprecision mediump float; uniform samplerExternalOES camera; varying vec2 imageUV; void main(){gl_FragColor=texture2D(camera,imageUV);}",
            )
            geometryProgram = program(
                "attribute vec3 position; uniform mat4 viewProjection; void main(){gl_Position=viewProjection*vec4(position,1.0);gl_PointSize=5.0;}",
                "precision mediump float; uniform vec4 color; void main(){gl_FragColor=color;}",
            )
            textureAssigned = false
        } catch (_: Exception) { failOnce() }
    }

    override fun onSurfaceChanged(gl: GL10?, width: Int, height: Int) {
        this.width = width.coerceAtLeast(1)
        this.height = height.coerceAtLeast(1)
        GLES20.glViewport(0, 0, width, height)
        displayDirty = true
    }

    override fun onDrawFrame(gl: GL10?) {
        GLES20.glClearColor(0.04f, 0.1f, 0.09f, 1f)
        GLES20.glClear(GLES20.GL_COLOR_BUFFER_BIT or GLES20.GL_DEPTH_BUFFER_BIT)
        if (failed || texture == 0) return
        try {
            if (!textureAssigned) {
                session.setCameraTextureName(texture)
                textureAssigned = true
            }
            val currentRotation = rotation()
            if (displayDirty || currentRotation != lastRotation) {
                session.setDisplayGeometry(currentRotation, width, height)
                lastRotation = currentRotation
                displayDirty = false
            }
            val frame = session.update()
            home?.frame(frame)
            if (frame.timestamp != 0L) drawBackground(frame)
            val tracking = frame.camera.trackingState == TrackingState.TRACKING
            val now = SystemClock.elapsedRealtime()
            if (now - lastSampleTime >= 250) {
                lastSampleTime = now
                if (tracking && frame.timestamp != lastFrameTimestamp && (home == null || home.collecting)) {
                    lastFrameTimestamp = frame.timestamp
                    samplePlanes(frame)
                    val sampledDepth = depthSupported && sampleDepth(frame)
                    if (sampledDepth) { capturedDepth = true; home?.markDepth() } else sampleFeatures(frame)
                    rebuildGeometryBuffers()
                } else if (!tracking && lastFrameTimestamp >= 0) {
                    geometry.markTrackingLimited()
                }
                onProgress(geometry.elementCount, geometry.pointCount, tracking)
            }
            if (tracking) drawGeometry(frame)
            home?.finishFrame(frame)
        } catch (_: Exception) { failOnce() }
    }

    private fun samplePlanes(frame: Frame) {
        val obsolete = planeIds.keys.filter { it.subsumedBy != null || it.trackingState == TrackingState.STOPPED }
        for (plane in obsolete) planeIds.remove(plane)?.let { geometry.removePlane(it) }
        val candidates = if (home == null) session.getAllTrackables(Plane::class.java)
            else (frame.getUpdatedTrackables(Plane::class.java) + planeIds.keys).distinct()
        for (plane in candidates) {
            if (plane.trackingState != TrackingState.TRACKING || plane.subsumedBy != null) continue
            var id = planeIds[plane]
            if (id == null) {
                if (planeIds.size >= BathroomScanGeometry.MAX_ELEMENTS) {
                    geometry.markCountLimit()
                    continue
                }
                if (home != null && plane !in homePlaneIds && homePlaneIds.size >= 2048) {
                    geometry.markCountLimit(); continue
                }
                id = if (home == null) UUID.randomUUID().toString()
                    else homePlaneIds.getOrPut(plane) { UUID.randomUUID().toString() }
                planeIds[plane] = id
            }
            val transform = FloatArray(16)
            (home?.localPose(plane.centerPose) ?: plane.centerPose).toMatrix(transform, 0)
            val category = when (plane.type) {
                Plane.Type.HORIZONTAL_UPWARD_FACING -> "horizontal_upward"
                Plane.Type.HORIZONTAL_DOWNWARD_FACING -> "horizontal_downward"
                else -> "vertical"
            }
            geometry.addPlane(id, category, plane.extentX, plane.extentZ, transform)
        }
    }

    private fun sampleDepth(frame: Frame): Boolean {
        var accepted = false
        try {
            frame.acquireRawDepthImage16Bits().use { depth ->
                if (depth.timestamp == lastDepthTimestamp) return false
                frame.acquireRawDepthConfidenceImage().use { confidence ->
                    if (confidence.width != depth.width || confidence.height != depth.height) return false
                    lastDepthTimestamp = depth.timestamp
                    val intrinsics = frame.camera.textureIntrinsics
                    val size = intrinsics.imageDimensions
                    val focal = intrinsics.focalLength
                    val center = intrinsics.principalPoint
                    if (size[0] <= 0 || size[1] <= 0) return false
                    val fx = focal[0] * depth.width / size[0]
                    val fy = focal[1] * depth.height / size[1]
                    val cx = center[0] * depth.width / size[0]
                    val cy = center[1] * depth.height / size[1]
                    val transform = FloatArray(16)
                    frame.camera.pose.toMatrix(transform, 0)
                    val depthPlane = depth.planes[0]
                    val confidencePlane = confidence.planes[0]
                    val depths = depthPlane.buffer.duplicate().order(ByteOrder.LITTLE_ENDIAN)
                    val confidences = confidencePlane.buffer.duplicate()
                    val step = ceil(sqrt(depth.width.toDouble() * depth.height / 600.0)).toInt().coerceAtLeast(1)
                    var inspected = 0
                    for (y in 0 until depth.height step step) {
                        for (x in 0 until depth.width step step) {
                            if (inspected++ >= 600) return accepted
                            val rawConfidence = BathroomScanGeometry.readPlaneValue(
                                confidences, confidence.width, confidence.height, confidencePlane.rowStride,
                                confidencePlane.pixelStride, x, y, 1,
                            ) ?: run { geometry.markOmitted(); return accepted }
                            val certainty = rawConfidence / 255f
                            if (certainty < 0.5f) continue
                            val millimeters = BathroomScanGeometry.readPlaneValue(
                                depths, depth.width, depth.height, depthPlane.rowStride,
                                depthPlane.pixelStride, x, y, 2,
                            ) ?: run { geometry.markOmitted(); return accepted }
                            val point = BathroomScanGeometry.unprojectDepth(x, y, millimeters, fx, fy, cx, cy, transform) ?: continue
                            accepted = addPoint(point, certainty) || accepted
                        }
                    }
                }
            }
        } catch (_: NotYetAvailableException) {
        }
        return accepted
    }

    private fun sampleFeatures(frame: Frame) {
        frame.acquirePointCloud().use { cloud ->
            val points = cloud.points.slice()
            val count = points.remaining() / 4
            val stride = ceil(count / 600.0).toInt().coerceAtLeast(1)
            for (index in 0 until count step stride) {
                val offset = index * 4
                addPoint(floatArrayOf(points.get(offset), points.get(offset + 1), points.get(offset + 2)), points.get(offset + 3))
            }
        }
    }

    private fun addPoint(world: FloatArray, confidence: Float): Boolean {
        val p = home?.localPoint(world) ?: world
        return geometry.addPoint(p[0], p[1], p[2], confidence)
    }
    fun requestHomeFinish(callback: (HomeScanCollector.Step) -> Unit) { home!!.requestFinish(callback) }
    fun startNextRoom() {
        home!!.startNext(); planeIds.clear()
        capturedDepth = false; lastFrameTimestamp = -1; lastSampleTime = 0
        rebuildGeometryBuffers()
    }
    fun closeHome() { home?.close(); homePlaneIds.clear(); planeIds.clear() }

    private fun rebuildGeometryBuffers() {
        pointVertices.clear()
        val points = geometry.pointSamples()
        for (point in points) pointVertices.put(point[0].toFloat()).put(point[1].toFloat()).put(point[2].toFloat())
        renderedPoints = points.size
        pointVertices.rewind()
        lineVertices.clear()
        renderedLines = 0
        for (plane in geometry.planeSamples()) {
            val x = plane.dimensions[0].toFloat() / 2
            val z = plane.dimensions[2].toFloat() / 2
            val corners = arrayOf(floatArrayOf(-x, -z), floatArrayOf(x, -z), floatArrayOf(x, z), floatArrayOf(-x, z))
            for (edge in 0..3) {
                for (corner in arrayOf(corners[edge], corners[(edge + 1) % 4])) {
                    for (row in 0..2) {
                        lineVertices.put((plane.transform[row] * corner[0] + plane.transform[8 + row] * corner[1] + plane.transform[12 + row]).toFloat())
                    }
                    renderedLines++
                }
            }
        }
        lineVertices.rewind()
    }

    private fun drawBackground(frame: Frame) {
        quad.rewind()
        textureCoordinates.rewind()
        frame.transformCoordinates2d(Coordinates2d.OPENGL_NORMALIZED_DEVICE_COORDINATES, quad, Coordinates2d.TEXTURE_NORMALIZED, textureCoordinates)
        quad.rewind()
        textureCoordinates.rewind()
        GLES20.glDisable(GLES20.GL_DEPTH_TEST)
        GLES20.glUseProgram(backgroundProgram)
        val position = GLES20.glGetAttribLocation(backgroundProgram, "position")
        val uv = GLES20.glGetAttribLocation(backgroundProgram, "uv")
        GLES20.glEnableVertexAttribArray(position)
        GLES20.glEnableVertexAttribArray(uv)
        GLES20.glVertexAttribPointer(position, 2, GLES20.GL_FLOAT, false, 0, quad)
        GLES20.glVertexAttribPointer(uv, 2, GLES20.GL_FLOAT, false, 0, textureCoordinates)
        GLES20.glActiveTexture(GLES20.GL_TEXTURE0)
        GLES20.glBindTexture(GLES11Ext.GL_TEXTURE_EXTERNAL_OES, texture)
        GLES20.glUniform1i(GLES20.glGetUniformLocation(backgroundProgram, "camera"), 0)
        GLES20.glDrawArrays(GLES20.GL_TRIANGLE_STRIP, 0, 4)
        GLES20.glDisableVertexAttribArray(position)
        GLES20.glDisableVertexAttribArray(uv)
    }

    private fun drawGeometry(frame: Frame) {
        frame.camera.getProjectionMatrix(projection, 0, 0.1f, 60f)
        frame.camera.getViewMatrix(view, 0)
        Matrix.multiplyMM(viewProjection, 0, projection, 0, view, 0)
        home?.localToWorld?.let { pose ->
            val transform = FloatArray(16); pose.toMatrix(transform, 0)
            val combined = FloatArray(16)
            Matrix.multiplyMM(combined, 0, viewProjection, 0, transform, 0)
            combined.copyInto(viewProjection)
        }
        GLES20.glUseProgram(geometryProgram)
        GLES20.glUniformMatrix4fv(GLES20.glGetUniformLocation(geometryProgram, "viewProjection"), 1, false, viewProjection, 0)
        val position = GLES20.glGetAttribLocation(geometryProgram, "position")
        val color = GLES20.glGetUniformLocation(geometryProgram, "color")
        GLES20.glEnableVertexAttribArray(position)
        GLES20.glUniform4f(color, 0.3f, 1f, 0.75f, 1f)
        GLES20.glVertexAttribPointer(position, 3, GLES20.GL_FLOAT, false, 0, pointVertices)
        GLES20.glDrawArrays(GLES20.GL_POINTS, 0, renderedPoints)
        GLES20.glUniform4f(color, 1f, 0.78f, 0.4f, 1f)
        GLES20.glVertexAttribPointer(position, 3, GLES20.GL_FLOAT, false, 0, lineVertices)
        GLES20.glLineWidth(2f)
        GLES20.glDrawArrays(GLES20.GL_LINES, 0, renderedLines)
        GLES20.glDisableVertexAttribArray(position)
    }

    private fun failOnce() {
        if (!failed) { failed = true; onFailure() }
    }

    private fun program(vertexSource: String, fragmentSource: String): Int {
        fun shader(type: Int, source: String): Int {
            val shader = GLES20.glCreateShader(type)
            GLES20.glShaderSource(shader, source)
            GLES20.glCompileShader(shader)
            val compiled = IntArray(1)
            GLES20.glGetShaderiv(shader, GLES20.GL_COMPILE_STATUS, compiled, 0)
            if (compiled[0] == 0) { GLES20.glDeleteShader(shader); error("shader") }
            return shader
        }
        val vertex = shader(GLES20.GL_VERTEX_SHADER, vertexSource)
        val fragment = try { shader(GLES20.GL_FRAGMENT_SHADER, fragmentSource) } catch (error: Exception) {
            GLES20.glDeleteShader(vertex)
            throw error
        }
        val program = GLES20.glCreateProgram()
        try {
            GLES20.glAttachShader(program, vertex)
            GLES20.glAttachShader(program, fragment)
            GLES20.glLinkProgram(program)
            val linked = IntArray(1)
            GLES20.glGetProgramiv(program, GLES20.GL_LINK_STATUS, linked, 0)
            if (linked[0] == 0) { GLES20.glDeleteProgram(program); error("program") }
            return program
        } finally {
            GLES20.glDeleteShader(vertex)
            GLES20.glDeleteShader(fragment)
        }
    }

    companion object {
        private fun direct(values: FloatArray): FloatBuffer = ByteBuffer.allocateDirect(values.size * 4)
            .order(ByteOrder.nativeOrder()).asFloatBuffer().apply { put(values); rewind() }
    }
}
