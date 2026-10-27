import AVFoundation
import ARKit
import Flutter
import SceneKit
import UIKit
import simd

enum BathroomARKitGeometry {
  static func plane(id: String, center: SIMD3<Float>, extent: SIMD3<Float>,
    transform: simd_float4x4, horizontal: Bool) throws -> [String: Any] {
    var centered = transform
    centered.columns.3 = transform * SIMD4<Float>(center.x, center.y, center.z, 1)
    return try BathroomScanGeometry.element(id: id, kind: "unknown",
      nativeCategory: horizontal ? "horizontal" : "vertical",
      dimensions: [Double(extent.x), 0, Double(extent.z)],
      transform: (0..<4).flatMap { column in (0..<4).map { Double(centered[column][$0]) } },
      confidence: "unknown")
  }

  static func measurement(id: String, start: SIMD3<Float>, end: SIMD3<Float>) throws -> [String: Any] {
    let coordinates = [start.x, start.y, start.z, end.x, end.y, end.z]
    let distance = simd_distance(SIMD3<Double>(start), SIMD3<Double>(end))
    guard BathroomScanGeometry.validScanID(id), coordinates.allSatisfy({ $0.isFinite && abs($0) <= 50 }),
      distance.isFinite, distance >= 0.02, distance <= 10 else { throw BathroomScanGeometry.Invalid.geometry }
    return ["id": id, "start": [Double(start.x), Double(start.y), Double(start.z)],
      "end": [Double(end.x), Double(end.y), Double(end.z)]]
  }
}

struct BathroomARKitMeasurements {
  struct Pending { let anchorID: UUID; let local: SIMD4<Float> }
  private(set) var pending: Pending?
  private(set) var values: [[String: Any]] = []
  mutating func resetPending() { pending = nil }
  mutating func undo() {
    if pending != nil { pending = nil }
    else if !values.isEmpty { values.removeLast() }
  }
  mutating func add(world: SIMD3<Float>, anchorID: UUID, transform: simd_float4x4) throws {
    guard values.count < 20 else { throw BathroomScanGeometry.Invalid.limit }
    guard let first = pending else {
      guard world.x.isFinite, world.y.isFinite, world.z.isFinite,
        abs(world.x) <= 50, abs(world.y) <= 50, abs(world.z) <= 50 else {
        throw BathroomScanGeometry.Invalid.geometry
      }
      pending = Pending(anchorID: anchorID,
        local: transform.inverse * SIMD4<Float>(world.x, world.y, world.z, 1))
      return
    }
    guard first.anchorID == anchorID else { throw BathroomScanGeometry.Invalid.geometry }
    let point = transform * first.local
    let value = try BathroomARKitGeometry.measurement(id: UUID().uuidString.lowercased(),
      start: SIMD3<Float>(point.x, point.y, point.z), end: world)
    values.append(value)
    pending = nil
  }
}

@MainActor
final class BathroomARKitCaptureController: UIViewController, BathroomNativeScanController, ARSessionDelegate {
  private let scanID: String
  private let language: String
  private let roomName: String?
  private let completion: FlutterResult
  private let camera = ARSCNView(frame: .zero)
  private let status = UILabel()
  private let measure = UIButton(type: .system)
  private let undo = UIButton(type: .system)
  private let finish = UIButton(type: .system)
  private let overlay = SCNNode()
  private let idleTimer = BathroomScanIdleTimerLease(read: { UIApplication.shared.isIdleTimerDisabled },
    write: { UIApplication.shared.isIdleTimerDisabled = $0 })
  private var poll: Timer?
  private var deadline: Timer?
  private var observers: [NSObjectProtocol] = []
  private var started = false, finished = false, trackingWasLimited = false
  private var estimates = BathroomARKitMeasurements()
  private var feedbackUntil = Date.distantPast
  private var lastStatus: String?
  private var stableFrames = 0

  init(scanID: String, language: String, roomName: String? = nil, completion: @escaping FlutterResult) {
    self.scanID = scanID; self.language = language; self.roomName = roomName; self.completion = completion
    super.init(nibName: nil, bundle: nil)
  }
  required init?(coder: NSCoder) { fatalError("Storyboard construction is not supported") }
  private func text(_ value: String) -> String { BathroomScanText.text(value, language: language) }

  override func viewDidLoad() {
    super.viewDidLoad()
    view.backgroundColor = .systemBackground
    camera.scene = SCNScene()
    camera.scene.rootNode.addChildNode(overlay)
    camera.preferredFramesPerSecond = 30
    camera.accessibilityLabel = text("Camera surface preview")
    let crosshair = UILabel()
    crosshair.text = "+"; crosshair.font = .systemFont(ofSize: 32, weight: .medium)
    crosshair.textColor = .white; crosshair.backgroundColor = UIColor.black.withAlphaComponent(0.5)
    crosshair.textAlignment = .center; crosshair.isAccessibilityElement = false
    crosshair.translatesAutoresizingMaskIntoConstraints = false
    camera.addSubview(crosshair)
    NSLayoutConstraint.activate([
      crosshair.centerXAnchor.constraint(equalTo: camera.centerXAnchor),
      crosshair.centerYAnchor.constraint(equalTo: camera.centerYAnchor),
      crosshair.widthAnchor.constraint(equalToConstant: 40), crosshair.heightAnchor.constraint(equalToConstant: 40),
    ])
    measure.addTarget(self, action: #selector(addPoint), for: .touchUpInside)
    undo.addTarget(self, action: #selector(undoPoint), for: .touchUpInside)
    measure.accessibilityIdentifier = "arkit-add-point"
    undo.accessibilityIdentifier = "arkit-undo-point"
    for button in [measure, undo] {
      button.titleLabel?.font = .preferredFont(forTextStyle: .headline)
      button.titleLabel?.adjustsFontForContentSizeCategory = true
      button.titleLabel?.numberOfLines = 0
      button.titleLabel?.textAlignment = .center
      button.heightAnchor.constraint(greaterThanOrEqualToConstant: 48).isActive = true
    }
    undo.setTitle(text("Undo point or distance"), for: .normal)
    let controls = UIStackView(arrangedSubviews: [camera, measure, undo])
    controls.axis = .vertical; controls.spacing = 4
    camera.heightAnchor.constraint(greaterThanOrEqualToConstant: 140).isActive = true
    let cancel = UIButton(type: .system)
    cancel.addTarget(self, action: #selector(cancelScan), for: .touchUpInside)
    finish.addTarget(self, action: #selector(finishScan), for: .touchUpInside)
    let layout = BathroomScanCaptureLayout(camera: controls, status: status, cancelButton: cancel,
      finishButton: finish, language: language)
    layout.heading.text = text("Camera-only scan") + (roomName.map { "\n" + $0 } ?? "")
    layout.translatesAutoresizingMaskIntoConstraints = false
    view.addSubview(layout)
    NSLayoutConstraint.activate([
      layout.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 12),
      layout.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -12),
      layout.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 16),
      layout.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -16),
    ])
    updateControls(ready: false, hasSurfaces: false)
    showStatus("Move slowly to find surfaces. Keep a clear path; photos and manual assessment are always available.")
    for name in [UIApplication.willResignActiveNotification, UIApplication.didEnterBackgroundNotification,
      ProcessInfo.thermalStateDidChangeNotification] {
      observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
        Task { @MainActor [weak self] in
          guard let self else { return }
          if name != ProcessInfo.thermalStateDidChangeNotification {
            self.fail("scan_interrupted"); return
          }
          if let failure = BathroomScanReadiness.failure(applicationState: UIApplication.shared.applicationState,
            authorization: AVCaptureDevice.authorizationStatus(for: .video), thermalState: ProcessInfo.processInfo.thermalState) {
            self.complete(failure)
          }
        }
      })
    }
  }

  override func viewDidAppear(_ animated: Bool) {
    super.viewDidAppear(animated)
    guard !started, !finished else { return }
    guard ARWorldTrackingConfiguration.isSupported else { fail("scan_unavailable"); return }
    if let failure = BathroomScanReadiness.failure(applicationState: UIApplication.shared.applicationState,
      authorization: AVCaptureDevice.authorizationStatus(for: .video), thermalState: ProcessInfo.processInfo.thermalState) {
      complete(failure); return
    }
    started = true; idleTimer.acquire()
    let configuration = ARWorldTrackingConfiguration()
    configuration.planeDetection = [.horizontal, .vertical]
    configuration.environmentTexturing = .none
    camera.session.delegate = self
    camera.session.run(configuration)
    let poll = Timer(timeInterval: 0.3, repeats: true) { [weak self] _ in
      Task { @MainActor [weak self] in self?.refresh() }
    }
    self.poll = poll; RunLoop.main.add(poll, forMode: .common)
    let deadline = Timer(timeInterval: 180, repeats: false) { [weak self] _ in
      Task { @MainActor [weak self] in self?.fail("scan_limit") }
    }
    self.deadline = deadline; RunLoop.main.add(deadline, forMode: .common)
  }

  private func trackedFrame() -> ARFrame? {
    guard !finished, let frame = camera.session.currentFrame,
      ProcessInfo.processInfo.systemUptime - frame.timestamp < 1,
      case .normal = frame.camera.trackingState else { return nil }
    return frame
  }

  private func planes(_ frame: ARFrame) -> [ARPlaneAnchor] {
    frame.anchors.compactMap { $0 as? ARPlaneAnchor }
      .sorted { $0.identifier.uuidString < $1.identifier.uuidString }
  }

  private func element(_ plane: ARPlaneAnchor) throws -> [String: Any] {
    try BathroomARKitGeometry.plane(id: plane.identifier.uuidString.lowercased(), center: plane.center,
      extent: plane.extent, transform: plane.transform, horizontal: plane.alignment == .horizontal)
  }

  private func refresh() {
    guard !finished else { return }
    guard let frame = trackedFrame() else {
      if stableFrames > 0 { trackingWasLimited = true }
      stableFrames = 0; estimates.resetPending(); feedbackUntil = .distantPast
      updateControls(ready: false, hasSurfaces: false)
      showStatus("Move slowly in good light. Point at a textured surface to restore tracking.")
      return
    }
    stableFrames = min(stableFrames + 1, 3)
    let surfaces = Array(planes(frame).prefix(128)).filter { (try? element($0)) != nil }
    if let pending = estimates.pending, !surfaces.contains(where: { $0.identifier == pending.anchorID }) {
      estimates.resetPending()
    }
    updateControls(ready: stableFrames >= 3, hasSurfaces: !surfaces.isEmpty)
    overlay.childNodes.forEach { $0.removeFromParentNode() }
    for plane in surfaces {
      let shape = SCNPlane(width: CGFloat(plane.extent.x), height: CGFloat(plane.extent.z))
      shape.firstMaterial?.diffuse.contents = UIColor.systemTeal.withAlphaComponent(0.25)
      shape.firstMaterial?.isDoubleSided = true
      let node = SCNNode(geometry: shape)
      node.eulerAngles.x = -.pi / 2
      node.simdPosition = plane.center
      let anchorNode = SCNNode(); anchorNode.simdTransform = plane.transform
      anchorNode.addChildNode(node); overlay.addChildNode(anchorNode)
    }
    for value in estimates.values {
      if let start = value["start"] as? [Double], let end = value["end"] as? [Double] {
        let line = SCNGeometry(sources: [SCNGeometrySource(vertices: [
          SCNVector3(start[0], start[1], start[2]), SCNVector3(end[0], end[1], end[2]),
        ])], elements: [SCNGeometryElement(indices: [Int32(0), Int32(1)], primitiveType: .line)])
        line.firstMaterial?.diffuse.contents = UIColor.systemYellow
        overlay.addChildNode(SCNNode(geometry: line))
      }
    }
    if let pending = estimates.pending, let anchor = surfaces.first(where: { $0.identifier == pending.anchorID }) {
      let dot = SCNNode(geometry: SCNSphere(radius: 0.012))
      let point = anchor.transform * pending.local
      dot.simdPosition = SIMD3<Float>(point.x, point.y, point.z)
      dot.geometry?.firstMaterial?.diffuse.contents = UIColor.systemYellow
      overlay.addChildNode(dot)
    }
    if surfaces.isEmpty { showStatus("Move slowly to find surfaces. Keep a clear path; photos and manual assessment are always available.") }
    else if estimates.pending != nil { showStatus("Aim at the second point on the same highlighted surface, then add it.") }
    else { showStatus("Finish to review surfaces, or aim at two points on one highlighted surface to estimate a distance.") }
  }

  private func updateControls(ready: Bool, hasSurfaces: Bool) {
    measure.isEnabled = ready && hasSurfaces && estimates.values.count < 20
    finish.isEnabled = ready && hasSurfaces && estimates.pending == nil
    undo.isEnabled = estimates.pending != nil || !estimates.values.isEmpty
    measure.setTitle(text(estimates.pending == nil ? "Add first point (optional)" : "Add second point"), for: .normal)
  }

  private func showStatus(_ message: String, feedback: Bool = false) {
    if feedback { feedbackUntil = Date().addingTimeInterval(4) }
    else if Date() < feedbackUntil { return }
    guard message != lastStatus else { return }
    lastStatus = message; status.text = text(message)
  }

  @objc private func addPoint() {
    guard trackedFrame() != nil, stableFrames >= 3, measure.isEnabled else { return }
    let center = CGPoint(x: camera.bounds.midX, y: camera.bounds.midY)
    guard let query = camera.raycastQuery(from: center, allowing: .existingPlaneGeometry, alignment: .any),
      let hit = camera.session.raycast(query).first, let anchor = hit.anchor as? ARPlaneAnchor else {
      showStatus("Aim at a highlighted surface and try again.", feedback: true); return
    }
    let position = hit.worldTransform.columns.3
    do {
      try estimates.add(world: SIMD3<Float>(position.x, position.y, position.z),
        anchorID: anchor.identifier, transform: anchor.transform)
      if estimates.pending == nil {
        UIAccessibility.post(notification: .announcement, argument: text("Distance estimate added. Review it after finishing."))
      }
      refresh()
    } catch {
      showStatus("Use two points on the same surface, 2 cm to 10 m apart. Undo to start again.", feedback: true)
    }
  }

  @objc private func undoPoint() { estimates.undo(); refresh() }
  @objc private func cancelScan() { fail("scan_cancelled") }
  @objc private func finishScan() {
    guard finish.isEnabled, estimates.pending == nil, let frame = trackedFrame() else { refresh(); return }
    var warnings: Set<String> = ["depth_unavailable"]
    if trackingWasLimited { warnings.insert("tracking_limited") }
    let all = planes(frame)
    var elements: [[String: Any]] = []
    for plane in all.prefix(128) {
      if let value = try? element(plane) { elements.append(value) }
      else { warnings.insert("geometry_omitted") }
    }
    if all.count > 128 { warnings.insert("count_limit") }
    do {
      let value = try BathroomScanGeometry.scene(scanID: scanID, capturedAt: Date(), elements: elements,
        warnings: warnings, truncated: all.count > 128, sourceVersion: "ARKit camera / iOS " + UIDevice.current.systemVersion,
        source: "arkit", measurements: estimates.values)
      complete(value)
    } catch { fail("scan_failed") }
  }

  nonisolated func session(_ session: ARSession, didFailWithError error: Error) {
    Task { @MainActor [weak self] in self?.fail("scan_failed") }
  }
  nonisolated func sessionWasInterrupted(_ session: ARSession) {
    Task { @MainActor [weak self] in self?.fail("scan_interrupted") }
  }
  override func viewDidDisappear(_ animated: Bool) {
    super.viewDidDisappear(animated)
    if !finished { fail("scan_interrupted") }
  }
  override func didReceiveMemoryWarning() { super.didReceiveMemoryWarning(); fail("scan_interrupted") }
  private func fail(_ code: String) { complete(BathroomScanPlatform.failure(code, "Camera scan stopped. Saved work is retained.")) }
  private func complete(_ value: Any?) {
    guard !finished else { return }
    stop(); completion(value)
  }
  private func stop() {
    finished = true
    poll?.invalidate(); poll = nil; deadline?.invalidate(); deadline = nil
    observers.forEach(NotificationCenter.default.removeObserver); observers.removeAll()
    camera.session.delegate = nil; camera.session.pause(); camera.isPlaying = false
    overlay.childNodes.forEach { $0.removeFromParentNode() }
    idleTimer.release()
  }
  func stopAndDismiss(completion: @escaping () -> Void) {
    stop()
    if presentingViewController != nil { dismiss(animated: false, completion: completion) }
    else { completion() }
  }
}
