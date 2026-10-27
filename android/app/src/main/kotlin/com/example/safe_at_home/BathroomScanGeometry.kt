package com.example.safe_at_home

import kotlin.math.abs
import kotlin.math.floor
import kotlin.math.round
import java.nio.ByteBuffer

class BathroomScanGeometry(val scanId: String) {
    init { require(isScanId(scanId)) }

    data class PlaneSample(
        val id: String,
        val category: String,
        val dimensions: List<Double>,
        val transform: List<Double>,
    ) {
        fun toMap(): Map<String, Any> = mapOf(
            "id" to id,
            "kind" to "unknown",
            "nativeCategory" to category,
            "dimensions" to dimensions,
            "transform" to transform,
            "classificationConfidence" to "unknown",
        )
    }

    private val planes = linkedMapOf<String, PlaneSample>()
    private val points = linkedMapOf<Triple<Int, Int, Int>, List<Double>>()
    private val warnings = linkedSetOf<String>()
    var truncated = false
        private set
    val elementCount: Int get() = planes.size
    val pointCount: Int get() = points.size

    fun markTrackingLimited() { warnings.add("tracking_limited") }
    fun markOmitted() { warnings.add("geometry_omitted") }

    fun removePlane(id: String) { planes.remove(id) }

    fun addPlane(id: String, category: String, x: Float, z: Float, transform: FloatArray): Boolean {
        if (id.isEmpty() || id.length > 80 || id.trim() != id || id.any { it.code < 32 || it.code == 127 } || category !in CATEGORIES ||
            !x.isFinite() || !z.isFinite() || x < 0.001f || z < 0.001f || x > 30 || z > 30 ||
            !isRigidTransform(transform)
        ) {
            planes.remove(id)
            markOmitted()
            return false
        }
        val sample = PlaneSample(
            id, category, listOf(rounded(x.toDouble()), 0.0, rounded(z.toDouble())),
            transform.map { rounded(it.toDouble()) },
        )
        if (!isRigidTransform(sample.transform) || !planeWithinWorldBounds(sample)) {
            planes.remove(id)
            markOmitted()
            return false
        }
        if (id !in planes && planes.size >= MAX_ELEMENTS) {
            markCountLimit()
            return false
        }
        planes[id] = sample
        return true
    }

    fun addPoint(x: Float, y: Float, z: Float, confidence: Float): Boolean {
        if (!x.isFinite() || !y.isFinite() || !z.isFinite() ||
            abs(x) > 50 || abs(y) > 50 || abs(z) > 50 ||
            !confidence.isFinite() || confidence !in 0.5f..1f
        ) return false
        val key = Triple(floor(x / VOXEL_METERS).toInt(), floor(y / VOXEL_METERS).toInt(), floor(z / VOXEL_METERS).toInt())
        val existing = points[key]
        if (existing != null && existing[3] >= confidence) return false
        if (existing == null && points.size >= MAX_POINTS) {
            markCountLimit()
            return false
        }
        points[key] = listOf(rounded(x.toDouble()), rounded(y.toDouble()), rounded(z.toDouble()), rounded(confidence.toDouble()))
        return true
    }

    fun markCountLimit() {
        truncated = true
        warnings.add("count_limit")
    }

    fun planeSamples(): List<PlaneSample> = planes.values.toList()
    fun pointSamples(): List<List<Double>> = points.values.toList()

    fun capPointSamples(maximum: Int) {
        require(maximum in 20..MAX_POINTS)
        if (points.size <= maximum) return
        val selected = evenlySpaced(points.entries.map { it.key to it.value }, maximum)
        points.clear()
        selected.forEach { (key, value) -> points[key] = value }
        markCountLimit()
    }

    fun absorb(other: BathroomScanGeometry, localToTarget: FloatArray) {
        require(isRigidTransform(localToTarget))
        warnings.addAll(other.warnings)
        if (other.truncated) truncated = true
        for (plane in other.planeSamples()) {
            val a = localToTarget.map { it.toDouble() }
            val b = plane.transform
            val matrix = FloatArray(16) { index ->
                val row = index % 4; val column = index / 4
                (0..3).sumOf { k -> a[k * 4 + row] * b[column * 4 + k] }.toFloat()
            }
            addPlane(plane.id, plane.category, plane.dimensions[0].toFloat(), plane.dimensions[2].toFloat(), matrix)
        }
        for (p in other.pointSamples()) {
            val point = FloatArray(3) { row ->
                (localToTarget[row] * p[0] + localToTarget[4 + row] * p[1] +
                    localToTarget[8 + row] * p[2] + localToTarget[12 + row]).toFloat()
            }
            if (!addPoint(point[0], point[1], point[2], p[3].toFloat()) &&
                point.any { !it.isFinite() || abs(it) > 50 }) markOmitted()
        }
    }

    fun scene(capturedAt: String, depthSupported: Boolean): Map<String, Any> {
        val finalWarnings = warnings.toMutableSet()
        finalWarnings.add(if (depthSupported) "depth_partial" else "depth_unavailable")
        return mapOf(
            "schemaVersion" to 1,
            "scanId" to scanId,
            "source" to "arcore",
            "sourceVersion" to "ARCore SDK 1.57.0",
            "capturedAt" to capturedAt,
            "units" to "m",
            "coordinateSystem" to "right_handed_y_up",
            "coverage" to "partial",
            "truncated" to truncated,
            "warnings" to finalWarnings.toList(),
            "elements" to planes.values.map { it.toMap() },
            "points" to pointSamples(),
        )
    }

    fun encodeSceneWithinLimit(capturedAt: String, depthSupported: Boolean,
        encode: (Map<String, Any>) -> String): String? =
        encodeSceneWithinLimit(capturedAt, depthSupported, MAX_JSON_BYTES, encode)

    fun encodeSceneWithinLimit(
        capturedAt: String,
        depthSupported: Boolean,
        maximumBytes: Int,
        encode: (Map<String, Any>) -> String,
    ): String? {
        require(maximumBytes in 4096..MAX_JSON_BYTES)
        val full = scene(capturedAt, depthSupported)
        val original = encode(full)
        if (original.toByteArray(Charsets.UTF_8).size <= maximumBytes) return original

        val allElements = planes.values.map { it.toMap() }
        val allPoints = pointSamples()
        val omittedWarnings = ((full["warnings"] as List<*>) + "geometry_omitted").distinct()
        fun candidate(elementCount: Int, pointCount: Int): String = encode(full + mapOf(
            "elements" to evenlySpaced(allElements, elementCount),
            "points" to evenlySpaced(allPoints, pointCount),
            "truncated" to true,
            "warnings" to omittedWarnings,
        ))
        var elementCount = allElements.size
        if (candidate(elementCount, 0).toByteArray(Charsets.UTF_8).size > maximumBytes) {
            elementCount = largestFittingCount(allElements.size) {
                candidate(it, 0).toByteArray(Charsets.UTF_8).size <= maximumBytes
            }
        }
        val pointCount = largestFittingCount(allPoints.size) {
            candidate(elementCount, it).toByteArray(Charsets.UTF_8).size <= maximumBytes
        }
        if (elementCount == 0 && pointCount < 20) return null
        return candidate(elementCount, pointCount).takeIf {
            it.toByteArray(Charsets.UTF_8).size <= maximumBytes
        }
    }

    companion object {
        const val MAX_ELEMENTS = 256
        const val MAX_POINTS = 4096
        const val MAX_JSON_BYTES = 240 * 1024
        const val VOXEL_METERS = 0.05f
        private val CATEGORIES = setOf("horizontal_upward", "horizontal_downward", "vertical")
        private val UUID_V4 = Regex("[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}", RegexOption.IGNORE_CASE)
        fun isScanId(value: String?): Boolean = value != null && UUID_V4.matches(value)
        private fun rounded(value: Double): Double = round(value * 1_000_000.0) / 1_000_000.0

        fun isRigidTransform(m: FloatArray): Boolean = isRigidTransform(m.map { it.toDouble() })

        private fun isRigidTransform(m: List<Double>): Boolean {
            if (m.size != 16 || m.any { !it.isFinite() }) return false
            if (abs(m[3]) > 0.0001 || abs(m[7]) > 0.0001 || abs(m[11]) > 0.0001 || abs(m[15] - 1) > 0.0001) return false
            if ((12..14).any { abs(m[it]) > 50 }) return false
            for (a in 0..2) {
                for (b in a..2) {
                    var dot = 0.0
                    for (row in 0..2) dot += m[a * 4 + row] * m[b * 4 + row]
                    if (abs(dot - if (a == b) 1.0 else 0.0) > 0.01) return false
                }
            }
            val determinant = m[0] * (m[5] * m[10] - m[9] * m[6]) -
                m[4] * (m[1] * m[10] - m[9] * m[2]) + m[8] * (m[1] * m[6] - m[5] * m[2])
            return abs(determinant - 1.0) <= 0.01
        }

        private fun planeWithinWorldBounds(plane: PlaneSample): Boolean {
            val m = plane.transform
            for (x in listOf(-plane.dimensions[0] / 2, plane.dimensions[0] / 2)) {
                for (z in listOf(-plane.dimensions[2] / 2, plane.dimensions[2] / 2)) {
                    for (row in 0..2) {
                        if (abs(m[row] * x + m[8 + row] * z + m[12 + row]) > 50) return false
                    }
                }
            }
            return true
        }

        private fun <T> evenlySpaced(values: List<T>, count: Int): List<T> {
            if (count == values.size) return values
            if (count == 0) return emptyList()
            if (count == 1) return listOf(values[values.size / 2])
            return List(count) { values[(it.toLong() * (values.size - 1) / (count - 1)).toInt()] }
        }

        private fun largestFittingCount(maximum: Int, fits: (Int) -> Boolean): Int {
            var low = 0
            var high = maximum
            while (low < high) {
                val mid = low + (high - low + 1) / 2
                if (fits(mid)) low = mid else high = mid - 1
            }
            return low
        }

        fun readPlaneValue(
            buffer: ByteBuffer, width: Int, height: Int, rowStride: Int, pixelStride: Int,
            x: Int, y: Int, bytesPerValue: Int,
        ): Int? {
            if (width <= 0 || height <= 0 || x !in 0 until width || y !in 0 until height ||
                bytesPerValue !in 1..2 || pixelStride < bytesPerValue || rowStride <= 0 ||
                (width - 1).toLong() * pixelStride + bytesPerValue > rowStride
            ) return null
            val offset = buffer.position().toLong() + y.toLong() * rowStride + x.toLong() * pixelStride
            if (offset < buffer.position() || offset + bytesPerValue > buffer.limit()) return null
            val low = buffer.get(offset.toInt()).toInt() and 255
            return if (bytesPerValue == 1) low else low or ((buffer.get(offset.toInt() + 1).toInt() and 255) shl 8)
        }

        fun unprojectDepth(
            x: Int, y: Int, millimeters: Int, fx: Float, fy: Float, cx: Float, cy: Float,
            cameraToWorld: FloatArray,
        ): FloatArray? {
            if (millimeters !in 200..8000 || !fx.isFinite() || !fy.isFinite() || fx <= 0 || fy <= 0 ||
                !cx.isFinite() || !cy.isFinite() || !isRigidTransform(cameraToWorld)
            ) return null
            val depth = millimeters / 1000f
            val localX = (x - cx) * depth / fx
            val localY = (cy - y) * depth / fy
            val localZ = -depth
            return FloatArray(3) { row ->
                cameraToWorld[row] * localX + cameraToWorld[4 + row] * localY +
                    cameraToWorld[8 + row] * localZ + cameraToWorld[12 + row]
            }
        }
    }
}
