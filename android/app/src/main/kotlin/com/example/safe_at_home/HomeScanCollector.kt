package com.example.safe_at_home

import com.google.ar.core.Anchor
import com.google.ar.core.Frame
import com.google.ar.core.Pose
import com.google.ar.core.Session
import com.google.ar.core.TrackingState
import org.json.JSONObject
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale
import java.util.TimeZone

internal class HomeScanCollector(private val session: Session, private val request: HomeScanRequest) {
    data class Step(val finishedRooms: Int, val payload: String? = null, val retry: Boolean = false)
    private data class Snapshot(val anchor: Anchor, val geometry: BathroomScanGeometry, val depth: Boolean)
    private val saved = mutableListOf<Snapshot>()
    private var anchor: Anchor? = null
    private var depth = false
    private var index = 0
    var betweenRooms = false
        private set
    var geometry = BathroomScanGeometry(request.rooms.first().token)
        private set
    private var finishRequest: ((Step) -> Unit)? = null
    val collecting: Boolean get() = !betweenRooms && anchor?.trackingState == TrackingState.TRACKING
    val localToWorld: Pose? get() = anchor?.pose

    fun frame(frame: Frame) {
        if (!betweenRooms && anchor == null && frame.camera.trackingState == TrackingState.TRACKING) {
            val p = frame.camera.pose
            anchor = session.createAnchor(Pose.makeTranslation(p.tx(), p.ty(), p.tz()))
        }
    }
    fun localPose(world: Pose): Pose = (anchor ?: error("missing anchor")).pose.inverse().compose(world)
    fun localPoint(world: FloatArray): FloatArray = (anchor ?: error("missing anchor")).pose.inverse().transformPoint(world)
    fun markDepth() { depth = true }
    fun requestFinish(callback: (Step) -> Unit) {
        check(finishRequest == null && !betweenRooms)
        finishRequest = callback
    }
    fun finishFrame(frame: Frame) {
        val callback = finishRequest ?: return
        finishRequest = null
        val a = anchor
        if (a == null || frame.camera.trackingState != TrackingState.TRACKING ||
            a.trackingState != TrackingState.TRACKING ||
            saved.any { it.anchor.trackingState != TrackingState.TRACKING } ||
            (geometry.elementCount == 0 && geometry.pointCount < 20)) {
            callback(Step(saved.size, retry = true)); return
        }
        saved.add(Snapshot(a, geometry, depth))
        betweenRooms = true
        callback(Step(saved.size, if (saved.size == request.rooms.size) encodeFinal() else null))
    }
    fun startNext() {
        check(betweenRooms && saved.size < request.rooms.size)
        index = saved.size
        geometry = BathroomScanGeometry(request.rooms[index].token)
        anchor = null; depth = false; betweenRooms = false
    }
    private fun encodeFinal(): String {
        check(saved.size == request.rooms.size && saved.all { it.anchor.trackingState == TrackingState.TRACKING })
        val root = saved.first().anchor.pose
        val worldToRoot = Pose.makeTranslation(-root.tx(), -root.ty(), -root.tz())
        val capturedAt = SimpleDateFormat("yyyy-MM-dd'T'HH:mm:ss.SSS'Z'", Locale.US).apply {
            timeZone = TimeZone.getTimeZone("UTC")
        }.format(Date())
        val rooms = saved.map { snapshot ->
            val transform = FloatArray(16)
            worldToRoot.compose(snapshot.anchor.pose).toMatrix(transform, 0)
            HomeScanAssembly.Room(snapshot.geometry, transform, snapshot.depth)
        }
        return HomeScanAssembly.encode(request, rooms, capturedAt) { JSONObject(it).toString() }
    }
    fun close() {
        finishRequest = null
        (saved.map { it.anchor } + listOfNotNull(anchor)).distinct().forEach { it.detach() }
        saved.clear(); anchor = null
    }
}
