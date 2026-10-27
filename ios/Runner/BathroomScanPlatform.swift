import AVFoundation
import ARKit
import Flutter
import RoomPlan
import UIKit
import simd

@MainActor
final class BathroomScanPlatform {
  private static var request: BathroomScanRequest?

  static func register(with registrar: FlutterPluginRegistrar) {
    let channel = FlutterMethodChannel(name: "safe_at_home/bathroom_scan", binaryMessenger: registrar.messenger())
    channel.setMethodCallHandler { call, result in
      switch call.method {
      case "capabilities": result(capabilities())
      case "homeCapabilities": result(["supported": homeSupported()])
      case "startHome": startHome(call.arguments, result: result)
      case "start": start(call.arguments, result: result)
      case "cancel":
        guard let scanID = requestID(call.arguments) else {
          result(failure("scan_failed", "The scan request is invalid.")); return
        }
        request?.cancel(scanID: scanID)
        result(nil)
      default: result(FlutterMethodNotImplemented)
      }
    }
  }

  static func capabilities() -> [String: Any] {
    #if targetEnvironment(simulator)
      return BathroomScanMode.capabilities(roomPlan: false, worldTracking: false,
        authorization: AVCaptureDevice.authorizationStatus(for: .video), simulator: true)
    #else
      var roomPlan = false
      if #available(iOS 16.0, *) { roomPlan = RoomCaptureSession.isSupported }
      return BathroomScanMode.capabilities(roomPlan: roomPlan,
        worldTracking: ARWorldTrackingConfiguration.isSupported,
        authorization: AVCaptureDevice.authorizationStatus(for: .video))
    #endif
  }

  static func homeSupported() -> Bool {
    guard #available(iOS 17.0, *) else { return false }
    return capabilities()["supported"] as? Bool == true && RoomCaptureSession.isSupported
  }

  private static func startHome(_ arguments: Any?, result: @escaping FlutterResult) {
    guard let input = HomeScanInput.parse(arguments) else {
      result(failure("scan_failed", "The scan request is invalid.")); return
    }
    guard request == nil else {
      result(failure("scan_busy", "Another room scan is already open.")); return
    }
    guard #available(iOS 17.0, *), homeSupported() else {
      result(failure("scan_unavailable", "Connected capture requires a supported LiDAR iPhone.")); return
    }
    let pending = BathroomScanRequest(scanID: input.id) { value in request = nil; result(value) }
    request = pending
    pending.begin(authorization: AVCaptureDevice.authorizationStatus(for: .video),
      requestPermission: { callback in AVCaptureDevice.requestAccess(for: .video) { granted in
        DispatchQueue.main.async { callback(granted) }
      } }, present: { [weak pending] in
        guard let pending else { return }
        if let problem = BathroomScanReadiness.failure(applicationState: UIApplication.shared.applicationState,
          authorization: AVCaptureDevice.authorizationStatus(for: .video), thermalState: ProcessInfo.processInfo.thermalState) {
          pending.complete(problem); return
        }
        guard let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene })
          .first(where: { $0.activationState == .foregroundActive }),
          var presenter = scene.windows.first(where: { $0.isKeyWindow })?.rootViewController else {
          pending.complete(failure("scan_interrupted", "Return to the app and start the scan again.")); return
        }
        while let shown = presenter.presentedViewController { presenter = shown }
        guard presenter.viewIfLoaded?.window != nil, !presenter.isBeingDismissed, !presenter.isBeingPresented else {
          pending.complete(failure("scan_unavailable", "Close the current screen and try scanning again.")); return
        }
        let controller = HomeRoomCaptureController(input: input) { [weak pending] value in pending?.complete(value) }
        pending.stopCapture = { [weak controller] done in
          guard let controller else { done(); return }; controller.stopAndDismiss(completion: done)
        }
        controller.modalPresentationStyle = .fullScreen; controller.isModalInPresentation = true
        presenter.present(controller, animated: true)
      })
  }

  static func requestID(_ arguments: Any?, allowLanguage: Bool = false) -> String? {
    guard let args = arguments as? [String: Any],
      Set(args.keys).isSubset(of: allowLanguage ? ["scanId", "languageCode", "room"] : ["scanId"]),
      args["room"] == nil || (allowLanguage && RoomScanContext.parse(args["room"]) != nil),
      args["languageCode"] == nil || (allowLanguage && ["en", "es", "zh-Hans", "zh-Hant", "vi", "fil"].contains(args["languageCode"] as? String ?? "")),
      let value = args["scanId"] as? String, BathroomScanGeometry.validScanID(value) else { return nil }
    return value
  }

  private static func start(_ arguments: Any?, result: @escaping FlutterResult) {
    guard let scanID = requestID(arguments, allowLanguage: true) else {
      result(failure("scan_failed", "The scan request is invalid.")); return
    }
    guard request == nil else {
      result(failure("scan_busy", "Another room scan is already open.")); return
    }
    let available = capabilities()
    guard available["supported"] as? Bool == true else {
      let denied = available["reason"] as? String == "permission_denied"
      result(failure(denied ? "scan_permission_denied" : "scan_unavailable",
        denied ? "Allow camera access in Settings to scan this room."
          : "Camera scanning is unavailable. Continue with photos and manual measurements.")); return
    }
    let pending = BathroomScanRequest(scanID: scanID) { value in
      request = nil
      result(value)
    }
    request = pending
    pending.begin(authorization: AVCaptureDevice.authorizationStatus(for: .video),
      requestPermission: { callback in
        AVCaptureDevice.requestAccess(for: .video) { granted in
          DispatchQueue.main.async { callback(granted) }
        }
      }, present: { [weak pending] in
        guard let pending else { return }
        if let failure = BathroomScanReadiness.failure(applicationState: UIApplication.shared.applicationState,
          authorization: AVCaptureDevice.authorizationStatus(for: .video), thermalState: ProcessInfo.processInfo.thermalState) {
          pending.complete(failure); return
        }
        guard let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene })
            .first(where: { $0.activationState == .foregroundActive }),
          let root = scene.windows.first(where: { $0.isKeyWindow })?.rootViewController else {
          pending.complete(failure("scan_interrupted", "Return to the app and start the scan again.")); return
        }
        var presenter = root
        while let shown = presenter.presentedViewController { presenter = shown }
        guard presenter.viewIfLoaded?.window != nil, !presenter.isBeingDismissed,
          !presenter.isBeingPresented else {
          pending.complete(failure("scan_unavailable", "Close the current screen and try scanning again.")); return
        }
        let language = (arguments as? [String: Any])?["languageCode"] as? String ?? "en"
        let room = RoomScanContext.parse((arguments as? [String: Any])?["room"])
        let controller: UIViewController & BathroomNativeScanController
        let complete: FlutterResult = { [weak pending] value in pending?.complete(value) }
        if #available(iOS 16.0, *), capabilities()["source"] as? String == "roomplan" {
          controller = BathroomRoomCaptureController(scanID: scanID, language: language, roomName: room?.name, completion: complete)
        } else if ARWorldTrackingConfiguration.isSupported {
          controller = BathroomARKitCaptureController(scanID: scanID, language: language, roomName: room?.name, completion: complete)
        } else {
          pending.complete(failure("scan_unavailable", "Camera scanning is unavailable.")); return
        }
        pending.stopCapture = { [weak controller] completion in
          guard let controller else { completion(); return }
          controller.stopAndDismiss(completion: completion)
        }
        controller.modalPresentationStyle = .fullScreen
        controller.isModalInPresentation = true
        presenter.present(controller, animated: true)
      })
  }

  static func failure(_ code: String, _ message: String) -> FlutterError {
    FlutterError(code: code, message: message, details: nil)
  }
}

struct RoomScanContext {
  enum RoomType: String { case bathroom, entrance, stairs, livingSpaces, bedroom, kitchen }
  let type: RoomType
  let name: String
  static func parse(_ value: Any?) -> RoomScanContext? {
    guard let room = value as? [String: Any], Set(room.keys) == ["type", "name"],
      let rawType = room["type"] as? String, let type = RoomType(rawValue: rawType),
      let name = room["name"] as? String, !name.isEmpty, name.unicodeScalars.count <= 80,
      name.trimmingCharacters(in: .whitespacesAndNewlines) == name,
      !name.unicodeScalars.contains(where: { scalar in
        let v = scalar.value
        return v < 32 || (127...159).contains(v) || (0x2028...0x202e).contains(v) || (0x2066...0x2069).contains(v)
      }) else { return nil }
    return RoomScanContext(type: type, name: name)
  }
}

@MainActor
protocol BathroomNativeScanController: AnyObject {
  func stopAndDismiss(completion: @escaping () -> Void)
}

enum BathroomScanMode {
  static func capabilities(roomPlan: Bool, worldTracking: Bool,
    authorization: AVAuthorizationStatus, simulator: Bool = false) -> [String: Any] {
    let source = roomPlan ? "roomplan" : "arkit"
    let denied = authorization == .denied || authorization == .restricted
    let capable = !simulator && (roomPlan || worldTracking)
    return ["supported": capable && !denied, "source": simulator ? "roomplan" : source,
      "reason": simulator ? "simulator" : !capable ? "unsupported_device" : denied ? "permission_denied" : "available",
      "depthSupported": !simulator && roomPlan]
  }
}

@MainActor
final class BathroomScanRequest {
  let scanID: String
  private(set) var completed = false
  private var completion: FlutterResult?
  var stopCapture: ((@escaping () -> Void) -> Void)?

  init(scanID: String, completion: @escaping FlutterResult) {
    self.scanID = scanID; self.completion = completion
  }

  func begin(authorization: AVAuthorizationStatus,
    requestPermission: (@escaping (Bool) -> Void) -> Void, present: @escaping () -> Void) {
    guard !completed else { return }
    switch authorization {
    case .authorized: present()
    case .notDetermined:
      requestPermission { [weak self] granted in
        guard let self, !self.completed else { return }
        if granted { present() }
        else { self.permissionDenied() }
      }
    default: permissionDenied()
    }
  }

  private func permissionDenied() {
    complete(BathroomScanPlatform.failure("scan_permission_denied", "Allow camera access in Settings to scan this room."))
  }

  func cancel(scanID: String) {
    guard self.scanID == scanID else { return }
    complete(BathroomScanPlatform.failure("scan_cancelled", "The room scan was cancelled."))
  }

  func complete(_ value: Any?) {
    guard !completed else { return }
    completed = true
    let callback = completion
    completion = nil
    let stop = stopCapture
    stopCapture = nil
    if let stop { stop { callback?(value) } }
    else { callback?(value) }
  }
}

final class BathroomScanLifecycle: @unchecked Sendable {
  enum Phase { case ready, scanning, processing, stopping, finished }
  enum ProcessingDecision { case allow, ignore, failed, unexpectedStop }
  private let lock = NSLock()
  private var storedPhase = Phase.ready
  private var processingClaimed = false

  var phase: Phase {
    lock.lock(); defer { lock.unlock() }
    return storedPhase
  }

  func start() -> Bool {
    lock.lock(); defer { lock.unlock() }
    guard storedPhase == .ready else { return false }
    storedPhase = .scanning
    return true
  }

  func requestProcessing() -> Bool {
    lock.lock(); defer { lock.unlock() }
    guard storedPhase == .scanning else { return false }
    storedPhase = .processing
    return true
  }

  func claimProcessing(succeeded: Bool) -> ProcessingDecision {
    lock.lock(); defer { lock.unlock() }
    guard storedPhase != .finished && storedPhase != .stopping else { return .ignore }
    guard succeeded else {
      storedPhase = .stopping
      return .failed
    }
    guard storedPhase == .processing else {
      storedPhase = .stopping
      return .unexpectedStop
    }
    guard !processingClaimed else { return .ignore }
    processingClaimed = true
    return .allow
  }

  var mayAcceptResult: Bool {
    lock.lock(); defer { lock.unlock() }
    return storedPhase == .processing && processingClaimed
  }

  @discardableResult
  func finish() -> Bool {
    lock.lock(); defer { lock.unlock() }
    guard storedPhase != .finished else { return false }
    storedPhase = .finished
    return true
  }
}

@MainActor
enum BathroomScanReadiness {
  static func failure(applicationState: UIApplication.State, authorization: AVAuthorizationStatus,
    thermalState: ProcessInfo.ThermalState) -> FlutterError? {
    guard applicationState == .active else {
      return BathroomScanPlatform.failure("scan_interrupted", "Return to the app and start the scan again.")
    }
    guard authorization == .authorized else {
      return BathroomScanPlatform.failure("scan_permission_denied", "Allow camera access in Settings to scan this room.")
    }
    guard thermalState == .nominal || thermalState == .fair else {
      return BathroomScanPlatform.failure("scan_interrupted", "Let your device cool before starting another scan.")
    }
    return nil
  }
}

@MainActor
final class BathroomScanIdleTimerLease {
  private let read: () -> Bool
  private let write: (Bool) -> Void
  private var previousValue: Bool?

  init(read: @escaping () -> Bool, write: @escaping (Bool) -> Void) {
    self.read = read; self.write = write
  }

  func acquire() {
    guard previousValue == nil else { return }
    previousValue = read()
    write(true)
  }

  func release() {
    guard let previousValue else { return }
    self.previousValue = nil
    write(previousValue)
  }
}

@MainActor
final class BathroomScanCaptureLayout: UIView {
  let captureScroll = UIScrollView()
  let heading = UILabel()

  init(camera: UIView, status: UILabel, cancelButton: UIButton, finishButton: UIButton, language: String = "en", roomName: String? = nil) {
    super.init(frame: .zero)
    heading.text = BathroomScanText.text("Scan this room", language: language) + (roomName.map { "\n" + $0 } ?? "")
    heading.font = .preferredFont(forTextStyle: .title2)
    heading.adjustsFontForContentSizeCategory = true
    heading.numberOfLines = 0
    heading.accessibilityTraits = .header
    status.text = BathroomScanText.text("Move slowly and follow the camera guidance. Stay on a safe, clear path. Scan only this room.", language: language)
    status.font = .preferredFont(forTextStyle: .body)
    status.adjustsFontForContentSizeCategory = true
    status.numberOfLines = 0
    for label in [heading, status] {
      label.setContentCompressionResistancePriority(.required, for: .vertical)
    }
    for (button, title) in [(cancelButton, "Cancel scan"), (finishButton, "Finish scan")] {
      button.setTitle(BathroomScanText.text(title, language: language), for: .normal)
      button.titleLabel?.font = .preferredFont(forTextStyle: .headline)
      button.titleLabel?.adjustsFontForContentSizeCategory = true
      button.titleLabel?.numberOfLines = 1
      button.titleLabel?.adjustsFontSizeToFitWidth = true
      button.titleLabel?.minimumScaleFactor = 0.5
      button.titleLabel?.textAlignment = .center
      button.setContentCompressionResistancePriority(.required, for: .vertical)
      button.heightAnchor.constraint(greaterThanOrEqualToConstant: 52).isActive = true
    }
    cancelButton.accessibilityIdentifier = "bathroom-scan-cancel"
    finishButton.accessibilityIdentifier = "bathroom-scan-finish"
    let introduction = UIStackView(arrangedSubviews: [heading, status])
    introduction.axis = .vertical; introduction.spacing = 8
    let captureContent = UIStackView(arrangedSubviews: [introduction, camera])
    captureContent.axis = .vertical; captureContent.spacing = 12
    captureContent.translatesAutoresizingMaskIntoConstraints = false
    captureScroll.addSubview(captureContent)
    captureScroll.alwaysBounceVertical = false
    captureScroll.isDirectionalLockEnabled = true
    let preferredCameraHeight = camera.heightAnchor.constraint(equalTo: heightAnchor, multiplier: 0.55)
    preferredCameraHeight.priority = .defaultLow
    let preferredContentHeight = captureContent.heightAnchor.constraint(equalTo: captureScroll.frameLayoutGuide.heightAnchor)
    preferredContentHeight.priority = .defaultHigh
    NSLayoutConstraint.activate([
      captureContent.leadingAnchor.constraint(equalTo: captureScroll.contentLayoutGuide.leadingAnchor),
      captureContent.trailingAnchor.constraint(equalTo: captureScroll.contentLayoutGuide.trailingAnchor),
      captureContent.topAnchor.constraint(equalTo: captureScroll.contentLayoutGuide.topAnchor),
      captureContent.bottomAnchor.constraint(equalTo: captureScroll.contentLayoutGuide.bottomAnchor),
      captureContent.widthAnchor.constraint(equalTo: captureScroll.frameLayoutGuide.widthAnchor),
      captureContent.heightAnchor.constraint(greaterThanOrEqualTo: captureScroll.frameLayoutGuide.heightAnchor),
      camera.heightAnchor.constraint(greaterThanOrEqualToConstant: 80),
      preferredContentHeight,
    ])
    let controls = UIStackView(arrangedSubviews: [cancelButton, finishButton])
    controls.axis = .vertical; controls.spacing = 4
    let stack = UIStackView(arrangedSubviews: [captureScroll, controls])
    stack.axis = .vertical; stack.spacing = 12; stack.translatesAutoresizingMaskIntoConstraints = false
    addSubview(stack)
    NSLayoutConstraint.activate([
      stack.topAnchor.constraint(equalTo: topAnchor),
      stack.bottomAnchor.constraint(equalTo: bottomAnchor),
      stack.leadingAnchor.constraint(equalTo: leadingAnchor),
      stack.trailingAnchor.constraint(equalTo: trailingAnchor),
      captureScroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 0),
      preferredCameraHeight,
    ])
    camera.setContentHuggingPriority(.defaultLow, for: .vertical)
  }

  required init?(coder: NSCoder) { fatalError("Storyboard construction is not supported") }
}

enum BathroomScanGeometry {
  enum Invalid: Error { case geometry, limit, empty }
  static let maximumElements = 256
  static let maximumBytes = 512 * 1024

  static func validScanID(_ value: String) -> Bool {
    value.utf8.count == 36 && value.range(of: "^[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-4[0-9A-Fa-f]{3}-[89ABab][0-9A-Fa-f]{3}-[0-9A-Fa-f]{12}$",
      options: .regularExpression) != nil
  }

  static func element(id: String, kind: String, nativeCategory: String,
    dimensions: [Double], transform: [Double], confidence: String) throws -> [String: Any] {
    let kinds: Set<String> = ["wall", "door", "opening", "window", "floor", "bathtub", "toilet", "sink", "storage", "furniture", "unknown"]
    guard !id.isEmpty, id.utf8.count <= 80, kinds.contains(kind), !nativeCategory.isEmpty,
      nativeCategory.utf8.count <= 64, ["low", "medium", "high", "unknown"].contains(confidence),
      dimensions.count == 3, dimensions.allSatisfy({ $0.isFinite && $0 >= 0 && $0 <= 30 }),
      dimensions.filter({ $0 > 0 }).count >= 2,
      transform.count == 16, transform.allSatisfy({ $0.isFinite }),
      [3, 7, 11].allSatisfy({ abs(transform[$0]) <= 0.0001 }), abs(transform[15] - 1) <= 0.0001,
      [12, 13, 14].allSatisfy({ abs(transform[$0]) <= 50 }) else { throw Invalid.geometry }
    let axes = (0..<3).map { column in SIMD3<Double>(transform[column * 4], transform[column * 4 + 1], transform[column * 4 + 2]) }
    guard axes.allSatisfy({ abs(simd_length($0) - 1) <= 0.01 }),
      abs(simd_dot(axes[0], axes[1])) <= 0.01,
      abs(simd_dot(axes[0], axes[2])) <= 0.01,
      abs(simd_dot(axes[1], axes[2])) <= 0.01,
      abs(simd_dot(simd_cross(axes[0], axes[1]), axes[2]) - 1) <= 0.03 else { throw Invalid.geometry }
    let origin = SIMD3<Double>(transform[12], transform[13], transform[14])
    for x in [-dimensions[0] / 2, dimensions[0] / 2] {
      for y in [-dimensions[1] / 2, dimensions[1] / 2] {
        for z in [-dimensions[2] / 2, dimensions[2] / 2] {
          let corner = origin + axes[0] * x + axes[1] * y + axes[2] * z
          guard abs(corner.x) <= 50, abs(corner.y) <= 50, abs(corner.z) <= 50 else { throw Invalid.geometry }
        }
      }
    }
    return ["id": id, "kind": kind, "nativeCategory": nativeCategory,
      "dimensions": dimensions, "transform": transform, "classificationConfidence": confidence]
  }

  static func scene(scanID: String, capturedAt: Date, elements: [[String: Any]],
    warnings: Set<String>, truncated: Bool, sourceVersion: String,
    source: String = "roomplan", measurements: [[String: Any]] = []) throws -> [String: Any] {
    guard validScanID(scanID), !elements.isEmpty else { throw Invalid.empty }
    guard elements.count <= maximumElements, warnings.count <= 16,
      sourceVersion.utf8.count <= 80 else { throw Invalid.limit }
    let allowed: Set<String> = ["curved_surfaces_approximated", "geometry_omitted", "depth_unavailable", "depth_partial", "tracking_limited", "count_limit"]
    guard warnings.isSubset(of: allowed), ["roomplan", "arkit"].contains(source),
      measurements.count <= 20, source == "arkit" || measurements.isEmpty else { throw Invalid.geometry }
    let date = ISO8601DateFormatter()
    date.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    date.timeZone = TimeZone(secondsFromGMT: 0)
    var value: [String: Any] = ["schemaVersion": source == "arkit" ? 2 : 1, "scanId": scanID,
      "source": source, "sourceVersion": sourceVersion, "capturedAt": date.string(from: capturedAt),
      "units": "m", "coordinateSystem": "right_handed_y_up", "coverage": "partial",
      "truncated": truncated, "warnings": warnings.sorted(), "elements": elements, "points": [[Double]]()]
    if source == "arkit" { value["measurements"] = measurements }
    let bytes = try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
    guard bytes.count <= maximumBytes else { throw Invalid.limit }
    return value
  }
}

@available(iOS 16.0, *)
@MainActor
private final class BathroomRoomCaptureController: UIViewController, RoomCaptureViewDelegate, BathroomNativeScanController {
  private nonisolated let lifecycle = BathroomScanLifecycle()
  private let idleTimer = BathroomScanIdleTimerLease(read: { UIApplication.shared.isIdleTimerDisabled },
    write: { UIApplication.shared.isIdleTimerDisabled = $0 })
  private let scanID: String
  private let language: String
  private let roomName: String?
  private let completion: FlutterResult
  private var captureView: RoomCaptureView?
  private var deadline: Timer?
  private var observers: [NSObjectProtocol] = []
  private let status = UILabel()
  private let finishButton = UIButton(type: .system)

  init(scanID: String, language: String = "en", roomName: String? = nil, completion: @escaping FlutterResult) {
    self.scanID = scanID; self.language = language; self.roomName = roomName; self.completion = completion
    super.init(nibName: nil, bundle: nil)
  }

  required init?(coder: NSCoder) { fatalError("Storyboard construction is not supported") }

  override func viewDidLoad() {
    super.viewDidLoad()
    view.backgroundColor = .systemBackground
    let camera = RoomCaptureView(frame: .zero)
    camera.delegate = self
    captureView = camera
    let cancel = UIButton(type: .system)
    cancel.addTarget(self, action: #selector(cancelScan), for: .touchUpInside)
    finishButton.addTarget(self, action: #selector(finishScan), for: .touchUpInside)
    let layout = BathroomScanCaptureLayout(camera: camera, status: status, cancelButton: cancel, finishButton: finishButton, language: language, roomName: roomName)
    layout.translatesAutoresizingMaskIntoConstraints = false
    view.addSubview(layout)
    NSLayoutConstraint.activate([
      layout.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 12),
      layout.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -12),
      layout.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 16),
      layout.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -16),
    ])
    for name in [UIApplication.willResignActiveNotification, UIApplication.didEnterBackgroundNotification] {
      observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
        Task { @MainActor [weak self] in
          self?.fail("scan_interrupted", "The scan was interrupted. Start again when you are ready.")
        }
      })
    }
    observers.append(NotificationCenter.default.addObserver(forName: ProcessInfo.thermalStateDidChangeNotification,
      object: nil, queue: .main) { [weak self] _ in
        if ProcessInfo.processInfo.thermalState == .critical || ProcessInfo.processInfo.thermalState == .serious {
          Task { @MainActor [weak self] in
            self?.fail("scan_interrupted", "Let your device cool before starting another scan.")
          }
        }
      })
  }

  override func viewDidAppear(_ animated: Bool) {
    super.viewDidAppear(animated)
    guard lifecycle.phase == .ready else { return }
    if let failure = BathroomScanReadiness.failure(applicationState: UIApplication.shared.applicationState,
      authorization: AVCaptureDevice.authorizationStatus(for: .video), thermalState: ProcessInfo.processInfo.thermalState) {
      complete(failure); return
    }
    guard lifecycle.start() else { return }
    idleTimer.acquire()
    var configuration = RoomCaptureSession.Configuration()
    configuration.isCoachingEnabled = true
    captureView?.captureSession.run(configuration: configuration)
    setDeadline(seconds: 180, message: "This scan reached its three-minute limit. Start a shorter room scan.")
  }

  override func viewDidDisappear(_ animated: Bool) {
    super.viewDidDisappear(animated)
    if lifecycle.phase != .finished { fail("scan_interrupted", "The scan closed before it was reviewed. Please scan again.") }
  }

  override func didReceiveMemoryWarning() {
    super.didReceiveMemoryWarning()
    fail("scan_interrupted", "The device needs more memory. Close other apps and try scanning again.")
  }

  private func setDeadline(seconds: TimeInterval, message: String) {
    deadline?.invalidate()
    let timer = Timer(timeInterval: seconds, repeats: false) { [weak self] _ in
      Task { @MainActor [weak self] in self?.fail("scan_limit", message) }
    }
    deadline = timer
    RunLoop.main.add(timer, forMode: .common)
  }

  @objc private func cancelScan() {
    fail("scan_cancelled", "The room scan was cancelled.")
  }

  @objc private func finishScan() {
    guard lifecycle.requestProcessing() else { return }
    finishButton.isEnabled = false
    status.text = BathroomScanText.text("Preparing the simplified 3D room. You will review and confirm it next.", language: language)
    UIAccessibility.post(notification: .announcement, argument: status.text)
    setDeadline(seconds: 30, message: "The room could not be prepared in time. Start a shorter scan.")
    captureView?.captureSession.stop()
  }

  nonisolated func captureView(shouldPresent roomDataForProcessing: CapturedRoomData, error: Error?) -> Bool {
    switch lifecycle.claimProcessing(succeeded: error == nil) {
    case .allow: return true
    case .ignore: return false
    case .failed:
      Task { @MainActor [weak self] in
        self?.fail("scan_failed", "Room scanning could not finish. Move to a clear, well-lit area and try again.")
      }
    case .unexpectedStop:
      Task { @MainActor [weak self] in
        self?.fail("scan_interrupted", "The scan stopped unexpectedly. Start the room scan again.")
      }
    }
    return false
  }

  nonisolated func captureView(didPresent processedResult: CapturedRoom, error: Error?) {
    let succeeded = error == nil
    Task { @MainActor [weak self] in
      self?.accept(processedResult, succeeded: succeeded)
    }
  }

  private func accept(_ processedResult: CapturedRoom, succeeded: Bool) {
    guard lifecycle.mayAcceptResult else { return }
    guard succeeded else {
      fail("scan_failed", "The room model could not be prepared. Please try again."); return
    }
    do {
      let payload = try Self.geometry(processedResult, scanID: scanID)
      complete(payload)
    } catch BathroomScanGeometry.Invalid.empty {
      fail("scan_failed", "No usable room geometry was found. Scan the walls and fixtures again.")
    } catch BathroomScanGeometry.Invalid.limit {
      fail("scan_limit", "This room model is too large. Scan only one room.")
    } catch {
      fail("scan_failed", "The room geometry could not be safely read. Please scan again.")
    }
  }

  static func geometry(_ room: CapturedRoom, scanID: String) throws -> [String: Any] {
    var floors: [CapturedRoom.Surface] = []
    if #available(iOS 17.0, *) { floors = room.floors }
    return try geometry(walls: room.walls, doors: room.doors, openings: room.openings,
      windows: room.windows, floors: floors, objects: room.objects, scanID: scanID)
  }

  static func geometry(walls: [CapturedRoom.Surface], doors: [CapturedRoom.Surface],
    openings: [CapturedRoom.Surface], windows: [CapturedRoom.Surface], floors: [CapturedRoom.Surface],
    objects: [CapturedRoom.Object], scanID: String) throws -> [String: Any] {
    var elements: [[String: Any]] = []
    var warnings = Set<String>()
    var truncated = false
    func add(id: UUID, kind: String, native: String, dimensions: SIMD3<Float>,
      transform: simd_float4x4, confidence: CapturedRoom.Confidence) {
      guard elements.count < BathroomScanGeometry.maximumElements else {
        truncated = true; warnings.insert("count_limit"); return
      }
      let categoryConfidence: String
      switch confidence {
      case .high: categoryConfidence = "high"
      case .medium: categoryConfidence = "medium"
      case .low: categoryConfidence = "low"
      @unknown default: categoryConfidence = "unknown"
      }
      let matrix = (0..<4).flatMap { column in (0..<4).map { row in Double(transform[column][row]) } }
      do {
        elements.append(try BathroomScanGeometry.element(id: id.uuidString.lowercased(), kind: kind,
          nativeCategory: native, dimensions: [Double(dimensions.x), Double(dimensions.y), Double(dimensions.z)],
          transform: matrix, confidence: categoryConfidence))
      } catch {
        warnings.insert("geometry_omitted"); truncated = true
      }
    }
    func surfaces(_ values: [CapturedRoom.Surface], kind: String) {
      for surface in values {
        if surface.curve != nil { warnings.insert("curved_surfaces_approximated") }
        add(id: surface.identifier, kind: kind, native: kind, dimensions: surface.dimensions,
          transform: surface.transform, confidence: surface.confidence)
      }
    }
    surfaces(walls, kind: "wall")
    surfaces(doors, kind: "door")
    surfaces(openings, kind: "opening")
    surfaces(windows, kind: "window")
    surfaces(floors, kind: "floor")
    for object in objects {
      let kind: String
      let native: String
      switch object.category {
      case .bathtub: kind = "bathtub"; native = "bathtub"
      case .toilet: kind = "toilet"; native = "toilet"
      case .sink: kind = "sink"; native = "sink"
      case .storage: kind = "storage"; native = "storage"
      case .refrigerator: kind = "furniture"; native = "refrigerator"
      case .stove: kind = "furniture"; native = "stove"
      case .bed: kind = "furniture"; native = "bed"
      case .washerDryer: kind = "furniture"; native = "washerDryer"
      case .oven: kind = "furniture"; native = "oven"
      case .dishwasher: kind = "furniture"; native = "dishwasher"
      case .table: kind = "furniture"; native = "table"
      case .sofa: kind = "furniture"; native = "sofa"
      case .chair: kind = "furniture"; native = "chair"
      case .fireplace: kind = "unknown"; native = "fireplace"
      case .television: kind = "furniture"; native = "television"
      case .stairs: kind = "unknown"; native = "stairs"
      @unknown default: kind = "unknown"; native = "unknown"
      }
      add(id: object.identifier, kind: kind, native: native, dimensions: object.dimensions,
        transform: object.transform, confidence: object.confidence)
    }
    return try BathroomScanGeometry.scene(scanID: scanID, capturedAt: Date(), elements: elements,
      warnings: warnings, truncated: truncated, sourceVersion: "RoomPlan / iOS " + UIDevice.current.systemVersion)
  }

  private func fail(_ code: String, _ message: String) {
    complete(BathroomScanPlatform.failure(code, message))
  }

  private func complete(_ value: Any?) {
    guard lifecycle.finish() else { return }
    stop()
    completion(value)
  }

  private func stop() {
    lifecycle.finish()
    idleTimer.release()
    deadline?.invalidate(); deadline = nil
    observers.forEach(NotificationCenter.default.removeObserver)
    observers.removeAll()
    captureView?.delegate = nil
    captureView?.captureSession.stop()
    captureView?.captureSession.arSession.pause()
  }

  func stopAndDismiss(completion: @escaping () -> Void) {
    stop()
    if presentingViewController != nil {
      dismiss(animated: false, completion: completion)
    } else { completion() }
  }
}

struct HomeScanInput {
  let id: String
  let language: String
  let rooms: [(token: String, name: String)]
  static func parse(_ value: Any?) -> HomeScanInput? {
    guard let args = value as? [String: Any], Set(args.keys) == ["scanId", "languageCode", "rooms"],
      let id = args["scanId"] as? String, BathroomScanGeometry.validScanID(id),
      let language = args["languageCode"] as? String,
      ["en", "es", "zh-Hans", "zh-Hant", "vi", "fil"].contains(language),
      let raw = args["rooms"] as? [[String: Any]], (2...8).contains(raw.count) else { return nil }
    var rooms: [(token: String, name: String)] = []
    var tokens = Set<String>()
    for room in raw {
      guard Set(room.keys) == ["token", "name"], let token = room["token"] as? String,
        BathroomScanGeometry.validScanID(token), tokens.insert(token.lowercased()).inserted,
        let name = room["name"] as? String, !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
        name.utf16.count <= 80, !name.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else { return nil }
      rooms.append((token: token, name: name))
    }
    return HomeScanInput(id: id, language: language, rooms: rooms)
  }
}

@available(iOS 17.0, *)
@objc(SAHHomeRoomDelegate)
private final class HomeRoomDelegate: NSObject, RoomCaptureViewDelegate, @unchecked Sendable {
  let lifecycle = BathroomScanLifecycle()
  let index: Int
  private let accepted: @MainActor (Int, CapturedRoom?, Bool) -> Void
  init(index: Int, accepted: @escaping @MainActor (Int, CapturedRoom?, Bool) -> Void) {
    self.index = index; self.accepted = accepted
  }
  required init?(coder: NSCoder) { fatalError("Storyboard construction is not supported") }
  func encode(with coder: NSCoder) { }
  nonisolated func captureView(shouldPresent data: CapturedRoomData, error: Error?) -> Bool {
    switch lifecycle.claimProcessing(succeeded: error == nil) {
    case .allow: return true
    case .ignore: return false
    case .failed, .unexpectedStop:
      Task { @MainActor [weak self] in guard let self else { return }; accepted(index, nil, false) }
      return false
    }
  }
  nonisolated func captureView(didPresent result: CapturedRoom, error: Error?) {
    let succeeded = error == nil
    Task { @MainActor [weak self] in
      guard let self, lifecycle.mayAcceptResult else { return }
      accepted(index, result, succeeded)
    }
  }
}

@available(iOS 17.0, *)
@MainActor
private final class HomeRoomCaptureController: UIViewController, BathroomNativeScanController {
  private let input: HomeScanInput
  private let completion: FlutterResult
  private let captureView = RoomCaptureView(frame: .zero)
  private let status = UILabel()
  private let finishButton = UIButton(type: .system)
  private var layout: BathroomScanCaptureLayout?
  private var delegateLease: HomeRoomDelegate?
  private var rooms: [CapturedRoom] = []
  private var index = 0
  private var betweenRooms = false, done = false, started = false, merging = false
  private var deadline: Timer?, totalDeadline: Timer?
  private var observers: [NSObjectProtocol] = []
  private var mergeTask: Task<Void, Never>?
  private let idleTimer = BathroomScanIdleTimerLease(read: { UIApplication.shared.isIdleTimerDisabled },
    write: { UIApplication.shared.isIdleTimerDisabled = $0 })
  init(input: HomeScanInput, completion: @escaping FlutterResult) {
    self.input = input; self.completion = completion
    super.init(nibName: nil, bundle: nil)
  }
  required init?(coder: NSCoder) { fatalError("Storyboard construction is not supported") }
  private func text(_ value: String) -> String { BathroomScanText.text(value, language: input.language) }
  override func viewDidLoad() {
    super.viewDidLoad(); view.backgroundColor = .systemBackground
    captureView.isModelEnabled = false
    let cancel = UIButton(type: .system)
    cancel.addTarget(self, action: #selector(cancelScan), for: .touchUpInside)
    finishButton.addTarget(self, action: #selector(advance), for: .touchUpInside)
    let layout = BathroomScanCaptureLayout(camera: captureView, status: status,
      cancelButton: cancel, finishButton: finishButton, language: input.language)
    self.layout = layout; layout.translatesAutoresizingMaskIntoConstraints = false
    view.addSubview(layout)
    NSLayoutConstraint.activate([
      layout.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 16),
      layout.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -16),
      layout.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 12),
      layout.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -12),
    ])
    for name in [UIApplication.willResignActiveNotification, UIApplication.didEnterBackgroundNotification] {
      observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
        Task { @MainActor [weak self] in self?.fail("scan_interrupted") }
      })
    }
    observers.append(NotificationCenter.default.addObserver(forName: ProcessInfo.thermalStateDidChangeNotification,
      object: nil, queue: .main) { [weak self] _ in Task { @MainActor [weak self] in
        if ProcessInfo.processInfo.thermalState == .serious || ProcessInfo.processInfo.thermalState == .critical {
          self?.fail("scan_interrupted")
        }
      } })
  }
  override func viewDidAppear(_ animated: Bool) {
    super.viewDidAppear(animated)
    guard !started, !done else { return }; started = true
    idleTimer.acquire()
    let timer = Timer(timeInterval: 900, repeats: false) { [weak self] _ in
      Task { @MainActor [weak self] in self?.fail("scan_limit") }
    }
    totalDeadline = timer; RunLoop.main.add(timer, forMode: .common)
    startRoom()
  }
  override func viewDidDisappear(_ animated: Bool) {
    super.viewDidDisappear(animated); if !done { fail("scan_interrupted") }
  }
  override func didReceiveMemoryWarning() { super.didReceiveMemoryWarning(); fail("scan_interrupted") }
  private func limit(_ seconds: TimeInterval) {
    deadline?.invalidate()
    let timer = Timer(timeInterval: seconds, repeats: false) { [weak self] _ in
      Task { @MainActor [weak self] in self?.fail("scan_limit") }
    }
    deadline = timer; RunLoop.main.add(timer, forMode: .common)
  }
  private func startRoom() {
    guard !done, index < input.rooms.count else { return }
    if let problem = BathroomScanReadiness.failure(applicationState: UIApplication.shared.applicationState,
      authorization: AVCaptureDevice.authorizationStatus(for: .video), thermalState: ProcessInfo.processInfo.thermalState) {
      complete(problem); return
    }
    let lease = HomeRoomDelegate(index: index) { [weak self] index, room, succeeded in
      self?.accept(index: index, room: room, succeeded: succeeded)
    }
    delegateLease = lease; captureView.delegate = lease
    guard lease.lifecycle.start() else { fail("scan_failed"); return }
    betweenRooms = false; finishButton.isEnabled = true
    finishButton.setTitle(text("Finish this room"), for: .normal)
    layout?.heading.text = "\(index + 1) / \(input.rooms.count) · " + input.rooms[index].name
    status.text = text("Scan only the named room. Keep the phone tracking while moving between rooms. Stay on one level and a safe, clear path.")
    UIAccessibility.post(notification: .announcement, argument: layout?.heading.text)
    var configuration = RoomCaptureSession.Configuration(); configuration.isCoachingEnabled = true
    captureView.captureSession.run(configuration: configuration)
    limit(180)
  }
  @objc private func advance() {
    guard !done, !merging else { return }
    if betweenRooms { startRoom(); return }
    guard let frame = captureView.captureSession.arSession.currentFrame,
      case .normal = frame.camera.trackingState else {
      status.text = text("Tracking is limited. Hold the phone steady in a well-lit area before finishing."); return
    }
    guard delegateLease?.lifecycle.requestProcessing() == true else { return }
    finishButton.isEnabled = false
    status.text = text("Preparing this room. Keep the phone tracking.")
    limit(30)
    captureView.captureSession.stop(pauseARSession: false)
  }
  private func accept(index callbackIndex: Int, room: CapturedRoom?, succeeded: Bool) {
    guard !done, !betweenRooms, !merging, callbackIndex == index else { return }
    guard succeeded, let room, delegateLease?.lifecycle.mayAcceptResult == true,
      !rooms.contains(where: { $0.identifier == room.identifier }) else { fail("scan_failed"); return }
    do { _ = try BathroomRoomCaptureController.geometry(room, scanID: input.rooms[index].token) }
    catch { fail("scan_failed"); return }
    delegateLease?.lifecycle.finish(); rooms.append(room)
    if rooms.count == input.rooms.count { merge(); return }
    index += 1; betweenRooms = true
    layout?.heading.text = "\(index + 1) / \(input.rooms.count) · " + input.rooms[index].name
    status.text = text("Keep the camera tracking. Move safely to the next named room, then start it. Cancelling retains your earlier saved models.")
    finishButton.setTitle(text("Start next room"), for: .normal); finishButton.isEnabled = true
    UIAccessibility.post(notification: .announcement, argument: status.text)
    limit(120)
  }
  private func merge() {
    merging = true; finishButton.isEnabled = false
    captureView.captureSession.arSession.pause()
    status.text = text("Joining rooms. Review their positions before saving.")
    limit(45)
    let captured = rooms
    mergeTask = Task { @MainActor [weak self] in
      do {
        let structure = try await StructureBuilder(options: [.beautifyObjects]).capturedStructure(from: captured)
        guard let self, !done, !Task.isCancelled else { return }
        let merged = try BathroomRoomCaptureController.geometry(walls: structure.walls, doors: structure.doors,
          openings: structure.openings, windows: structure.windows, floors: structure.floors,
          objects: structure.objects, scanID: input.id)
        let output: [[String: Any]] = try captured.enumerated().map { i, room in
          ["token": input.rooms[i].token,
            "scene": try BathroomRoomCaptureController.geometry(room, scanID: input.rooms[i].token)]
        }
        let payload: [String: Any] = ["version": 1, "sessionId": input.id, "rooms": output, "merged": merged]
        guard try JSONSerialization.data(withJSONObject: payload).count <= 6 * 1024 * 1024 else {
          fail("scan_limit"); return
        }
        complete(payload)
      } catch { self?.fail("scan_failed") }
    }
  }
  @objc private func cancelScan() { fail("scan_cancelled") }
  private func fail(_ code: String) {
    complete(BathroomScanPlatform.failure(code, "Connected capture could not finish. Your saved models are retained."))
  }
  private func complete(_ value: Any?) {
    guard !done else { return }; done = true; stop(); completion(value)
  }
  private func stop() {
    done = true; delegateLease?.lifecycle.finish(); captureView.delegate = nil
    captureView.captureSession.stop(pauseARSession: true); captureView.captureSession.arSession.pause()
    deadline?.invalidate(); totalDeadline?.invalidate(); deadline = nil; totalDeadline = nil
    mergeTask?.cancel(); mergeTask = nil
    observers.forEach(NotificationCenter.default.removeObserver); observers.removeAll()
    idleTimer.release(); rooms.removeAll()
  }
  func stopAndDismiss(completion: @escaping () -> Void) {
    stop(); if presentingViewController != nil { dismiss(animated: false, completion: completion) }
    else { completion() }
  }
}

enum BathroomScanText {
  static func text(_ english: String, language: String) -> String {
    messages[english]?[language] ?? english
  }
  private static let messages: [String: [String: String]] = [
    "Finish this room": [
      "es": "Terminar esta habitación",
      "zh-Hans": "完成此房间",
      "zh-Hant": "完成此房間",
      "vi": "Hoàn tất phòng này",
      "fil": "Tapusin ang kuwartong ito",
    ],
    "Start next room": [
      "es": "Iniciar siguiente habitación",
      "zh-Hans": "开始下一个房间",
      "zh-Hant": "開始下一個房間",
      "vi": "Bắt đầu phòng tiếp theo",
      "fil": "Simulan ang susunod na kuwarto",
    ],
    "Scan only the named room. Keep the phone tracking while moving between rooms. Stay on one level and a safe, clear path.": [
      "es": "Escanee solo la habitación indicada. Mantenga el seguimiento al moverse. Permanezca en el mismo nivel y en un camino seguro y despejado.",
      "zh-Hans": "仅扫描指定房间。在房间之间移动时保持手机跟踪。请保持在同一楼层和安全畅通的路线上。",
      "zh-Hant": "僅掃描指定房間。在房間之間移動時保持手機追蹤。請保持在同一樓層和安全暢通的路線上。",
      "vi": "Chỉ quét phòng được đặt tên. Giữ điện thoại theo dõi khi di chuyển giữa các phòng. Ở cùng một tầng và đi trên lối an toàn, thông thoáng.",
      "fil": "I-scan lamang ang pinangalanang kuwarto. Panatilihin ang tracking habang lumilipat. Manatili sa iisang palapag at sa ligtas, maluwag na daan.",
    ],
    "Tracking is limited. Hold the phone steady in a well-lit area before finishing.": [
      "es": "El seguimiento es limitado. Mantenga el teléfono estable en un lugar iluminado antes de terminar.",
      "zh-Hans": "跟踪受限。完成前请在光线充足的区域稳住手机。",
      "zh-Hant": "追蹤受限。完成前請在光線充足的區域穩住手機。",
      "vi": "Theo dõi bị hạn chế. Giữ điện thoại ổn định tại nơi đủ sáng trước khi hoàn tất.",
      "fil": "Limitado ang tracking. Hawakan nang matatag ang telepono sa maliwanag na lugar bago tapusin.",
    ],
    "Preparing this room. Keep the phone tracking.": [
      "es": "Preparando la habitación. Mantenga el seguimiento.",
      "zh-Hans": "正在处理此房间。请保持手机跟踪。",
      "zh-Hant": "正在處理此房間。請保持手機追蹤。",
      "vi": "Đang xử lý phòng này. Giữ điện thoại theo dõi.",
      "fil": "Inihahanda ang kuwartong ito. Panatilihin ang tracking.",
    ],
    "Keep the camera tracking. Move safely to the next named room, then start it. Cancelling retains your earlier saved models.": [
      "es": "Mantenga el seguimiento. Pase con cuidado a la siguiente habitación indicada y luego iníciela. Al cancelar se conservan los modelos anteriores.",
      "zh-Hans": "保持相机跟踪。安全移动到下一个指定房间，然后开始。取消会保留之前保存的模型。",
      "zh-Hant": "保持相機追蹤。安全移動到下一個指定房間，然後開始。取消會保留之前儲存的模型。",
      "vi": "Giữ camera theo dõi. Di chuyển an toàn đến phòng tiếp theo rồi bắt đầu. Hủy sẽ giữ lại các mô hình đã lưu trước đó.",
      "fil": "Panatilihin ang camera tracking. Ligtas na lumipat sa susunod na pinangalanang kuwarto, saka simulan ito. Pinapanatili ng pagkansela ang dating naka-save na mga modelo.",
    ],
    "Joining rooms. Review their positions before saving.": [
      "es": "Uniendo habitaciones. Revise las posiciones antes de guardar.",
      "zh-Hans": "正在连接房间。保存前请检查位置。",
      "zh-Hant": "正在連接房間。儲存前請檢查位置。",
      "vi": "Đang nối các phòng. Xem xét vị trí trước khi lưu.",
      "fil": "Ikinokonekta ang mga kuwarto. Suriin ang mga posisyon bago mag-save.",
    ],
    "Geometry stays private on this device. Backgrounding cancels the entire connected capture. Stay on one level; review room positions before saving.": [
      "es": "La geometría permanece privada en este dispositivo. Salir de la app cancela toda la captura conectada. Permanezca en un nivel y revise las posiciones antes de guardar.",
      "zh-Hans": "几何数据私密保存在此设备上。离开应用将取消整个连续扫描。请保持在同一楼层，保存前检查房间位置。",
      "zh-Hant": "幾何資料私密儲存在此裝置上。離開 App 將取消整個連續掃描。請保持在同一樓層，儲存前檢查房間位置。",
      "vi": "Dữ liệu hình học được giữ riêng trên thiết bị này. Rời ứng dụng sẽ hủy toàn bộ phiên quét nối phòng. Ở cùng một tầng và xem xét vị trí trước khi lưu.",
      "fil": "Pribado ang geometry sa device na ito. Makakansela ang buong konektadong scan kapag umalis sa app. Manatili sa iisang palapag at suriin ang posisyon bago mag-save.",
    ],
    "Scan this room": [
      "es": "Escanee esta habitación",
      "zh-Hans": "扫描此房间",
      "zh-Hant": "掃描此房間",
      "vi": "Quét phòng này",
      "fil": "I-scan ang kuwartong ito",
    ],
    "Move slowly and follow the camera guidance. Stay on a safe, clear path. Scan only this room.": [
      "es": "Muévase despacio y siga las indicaciones de la cámara. Permanezca en un camino seguro y despejado. Escanee solo esta habitación.",
      "zh-Hans": "缓慢移动并遵循相机指引。保持在安全、畅通的路径上。仅扫描此房间。",
      "zh-Hant": "緩慢移動並遵循相機指引。保持在安全、暢通的路徑上。僅掃描此房間。",
      "vi": "Di chuyển chậm và làm theo hướng dẫn camera. Đi trên lối an toàn, thông thoáng. Chỉ quét phòng này.",
      "fil": "Dahan-dahang gumalaw at sundin ang gabay ng camera. Manatili sa ligtas at maluwag na daanan. I-scan lamang ang kuwartong ito.",
    ],
    "Start room scan": [
      "es": "Iniciar escaneo de habitación",
      "zh-Hans": "开始房间扫描",
      "zh-Hant": "開始房間掃描",
      "vi": "Bắt đầu quét phòng",
      "fil": "Simulan ang pag-scan ng kuwarto",
    ],
    "Live room camera view. Detected surfaces and sampled points are outlined.": [
      "es": "Vista de cámara de la habitación en vivo. Se resaltan las superficies detectadas y los puntos muestreados.",
      "zh-Hans": "房间实时相机视图。已标出检测到的表面和采样点。",
      "zh-Hant": "房間即時相機檢視。已標出偵測到的表面和取樣點。",
      "vi": "Hình ảnh phòng trực tiếp từ camera. Các bề mặt và điểm lấy mẫu được đánh dấu.",
      "fil": "Live na camera ng kuwarto. May balangkas ang mga natukoy na ibabaw at sample na punto.",
    ],
    "Room scan": [
      "es": "Escaneo de habitación",
      "zh-Hans": "房间扫描",
      "zh-Hant": "房間掃描",
      "vi": "Quét phòng",
      "fil": "Pag-scan ng kuwarto",
    ],
    "Finding position. Move slowly while facing the room.": [
      "es": "Buscando posición. Muévase despacio mirando hacia la habitación.",
      "zh-Hans": "正在定位。请面向房间缓慢移动。",
      "zh-Hant": "正在定位。請面向房間緩慢移動。",
      "vi": "Đang xác định vị trí. Di chuyển chậm và hướng vào phòng.",
      "fil": "Hinahanap ang posisyon. Dahan-dahang gumalaw habang nakaharap sa kuwarto.",
    ],
    "Camera-only scan": [
      "es": "Escaneo solo con cámara",
      "zh-Hans": "仅相机扫描",
      "zh-Hant": "僅相機掃描",
      "vi": "Quét chỉ bằng camera",
      "fil": "Pag-scan gamit lang ang camera",
    ],
    "Camera surface preview": [
      "es": "Vista previa de superficies",
      "zh-Hans": "相机表面预览",
      "zh-Hant": "相機表面預覽",
      "vi": "Xem trước bề mặt qua camera",
      "fil": "Preview ng mga ibabaw sa camera",
    ],
    "Undo point or distance": [
      "es": "Deshacer punto o distancia",
      "zh-Hans": "撤销点或距离",
      "zh-Hant": "復原點或距離",
      "vi": "Hoàn tác điểm hoặc khoảng cách",
      "fil": "I-undo ang punto o distansya",
    ],
    "Add first point (optional)": [
      "es": "Añadir primer punto (opcional)",
      "zh-Hans": "添加起点（可选）",
      "zh-Hant": "新增起點（選填）",
      "vi": "Thêm điểm đầu (tùy chọn)",
      "fil": "Idagdag ang unang punto (opsyonal)",
    ],
    "Add second point": [
      "es": "Añadir segundo punto",
      "zh-Hans": "添加终点",
      "zh-Hant": "新增終點",
      "vi": "Thêm điểm thứ hai",
      "fil": "Idagdag ang ikalawang punto",
    ],
    "Move slowly to find surfaces. Keep a clear path; photos and manual assessment are always available.": [
      "es": "Muévase despacio para detectar superficies. Mantenga el paso despejado; siempre puede usar fotos y evaluación manual.",
      "zh-Hans": "缓慢移动以寻找表面。保持通道畅通；您随时可以使用照片和手动评估。",
      "zh-Hant": "緩慢移動以尋找表面。保持通道暢通；您隨時可以使用照片和手動評估。",
      "vi": "Di chuyển chậm để tìm bề mặt. Giữ lối đi thông thoáng; bạn luôn có thể dùng ảnh và đánh giá thủ công.",
      "fil": "Dahan-dahang kumilos para makita ang mga ibabaw. Panatilihing maluwag ang daan; maaari pa ring gumamit ng larawan at manwal na pagtatasa.",
    ],
    "Move slowly in good light. Point at a textured surface to restore tracking.": [
      "es": "Muévase despacio con buena luz. Apunte a una superficie con detalles para recuperar el seguimiento.",
      "zh-Hans": "在光线充足处缓慢移动。对准有纹理的表面以恢复跟踪。",
      "zh-Hant": "在光線充足處緩慢移動。對準有紋理的表面以恢復追蹤。",
      "vi": "Di chuyển chậm ở nơi đủ sáng. Hướng vào bề mặt có hoa văn để khôi phục theo dõi.",
      "fil": "Dahan-dahang kumilos sa maliwanag na lugar. Itutok sa ibabaw na may detalye para maibalik ang pagsubaybay.",
    ],
    "Aim at the second point on the same highlighted surface, then add it.": [
      "es": "Apunte al segundo punto de la misma superficie resaltada y añádalo.",
      "zh-Hans": "对准同一高亮表面上的终点，然后添加。",
      "zh-Hant": "對準同一醒目表面上的終點，然後新增。",
      "vi": "Hướng vào điểm thứ hai trên cùng bề mặt được tô sáng rồi thêm điểm.",
      "fil": "Itutok sa ikalawang punto sa parehong naka-highlight na ibabaw, saka idagdag ito.",
    ],
    "Finish to review surfaces, or aim at two points on one highlighted surface to estimate a distance.": [
      "es": "Termine para revisar las superficies, o marque dos puntos en una superficie resaltada para estimar una distancia.",
      "zh-Hans": "完成后可查看表面，或在同一高亮表面上选择两点来估算距离。",
      "zh-Hant": "完成後可查看表面，或在同一醒目表面上選擇兩點來估算距離。",
      "vi": "Hoàn tất để xem các bề mặt, hoặc chọn hai điểm trên cùng bề mặt được tô sáng để ước tính khoảng cách.",
      "fil": "Tapusin para suriin ang mga ibabaw, o pumili ng dalawang punto sa iisang naka-highlight na ibabaw para tantiyahin ang distansya.",
    ],
    "Aim at a highlighted surface and try again.": [
      "es": "Apunte a una superficie resaltada e inténtelo de nuevo.",
      "zh-Hans": "对准高亮表面后重试。",
      "zh-Hant": "對準醒目表面後再試。",
      "vi": "Hướng vào bề mặt được tô sáng rồi thử lại.",
      "fil": "Itutok sa naka-highlight na ibabaw at subukan muli.",
    ],
    "Distance estimate added. Review it after finishing.": [
      "es": "Estimación de distancia añadida. Revísela al terminar.",
      "zh-Hans": "已添加距离估算。完成后请查看。",
      "zh-Hant": "已新增距離估算。完成後請查看。",
      "vi": "Đã thêm khoảng cách ước tính. Xem lại sau khi hoàn tất.",
      "fil": "Naidagdag ang tantiya ng distansya. Suriin ito pagkatapos.",
    ],
    "Use two points on the same surface, 2 cm to 10 m apart. Undo to start again.": [
      "es": "Use dos puntos de la misma superficie, separados entre 2 cm y 10 m. Deshaga para empezar de nuevo.",
      "zh-Hans": "请在同一表面上选取间距为2厘米至10米的两点。撤销后可重新开始。",
      "zh-Hant": "請在同一表面上選取間距為2公分至10公尺的兩點。復原後可重新開始。",
      "vi": "Chọn hai điểm trên cùng bề mặt, cách nhau từ 2 cm đến 10 m. Hoàn tác để bắt đầu lại.",
      "fil": "Gumamit ng dalawang punto sa parehong ibabaw na 2 cm hanggang 10 m ang pagitan. I-undo para magsimulang muli.",
    ],
    "Start camera scan": [
      "es": "Iniciar escaneo con cámara",
      "zh-Hans": "开始相机扫描",
      "zh-Hant": "開始相機掃描",
      "vi": "Bắt đầu quét bằng camera",
      "fil": "Simulan ang pag-scan sa camera",
    ],
    "This iPhone uses camera-only scanning. Capture surfaces and optional distance estimates.": [
      "es": "Este iPhone escanea solo con la cámara. Capture superficies y, si quiere, estime distancias.",
      "zh-Hans": "此iPhone使用仅相机扫描，可采集表面并选择估算距离。",
      "zh-Hant": "此iPhone使用僅相機掃描，可擷取表面並選擇估算距離。",
      "vi": "iPhone này quét chỉ bằng camera. Ghi lại bề mặt và tùy chọn ước tính khoảng cách.",
      "fil": "Camera lang ang ginagamit ng iPhone na ito sa pag-scan. Kunan ang mga ibabaw at opsyonal na tantiyahin ang distansya.",
    ],
    "Camera-only surface model. Identify features yourself; detected patches are not full walls or clearances.": [
      "es": "Modelo de superficies obtenido solo con cámara. Identifique los elementos; las zonas detectadas no representan paredes completas ni espacios libres.",
      "zh-Hans": "仅相机表面模型。请自行识别物体；检测到的局部表面并非完整墙壁或通行净空。",
      "zh-Hant": "僅相機表面模型。請自行辨識物體；偵測到的局部表面並非完整牆壁或通行淨空。",
      "vi": "Mô hình bề mặt chỉ từ camera. Bạn cần tự xác định vật thể; các mảng phát hiện không phải toàn bộ tường hay khoảng trống sử dụng được.",
      "fil": "Modelo ng ibabaw mula sa camera lang. Ikaw ang tutukoy sa mga bagay; hindi buong dingding o maluwag na daanan ang mga natukoy na bahagi.",
    ],
    "Estimated distances": [
      "es": "Distancias estimadas",
      "zh-Hans": "估算距离",
      "zh-Hant": "估算距離",
      "vi": "Khoảng cách ước tính",
      "fil": "Mga tinantiyang distansya",
    ],
    "These camera estimates stay on this phone. Check important measurements with a tape measure.": [
      "es": "Estas estimaciones se guardan en este teléfono. Compruebe las medidas importantes con una cinta métrica.",
      "zh-Hans": "这些相机估算保存在此手机上。请用卷尺核实重要尺寸。",
      "zh-Hant": "這些相機估算保存在此手機上。請用捲尺核實重要尺寸。",
      "vi": "Các ước tính này được lưu trên điện thoại này. Kiểm tra số đo quan trọng bằng thước dây.",
      "fil": "Nananatili sa teleponong ito ang mga tantiya. Suriin ang mahahalagang sukat gamit ang metro.",
    ],
    "Distance {number}: about {metres} m": [
      "es": "Distancia {number}: aprox. {metres} m",
      "zh-Hans": "距离{number}：约{metres}米",
      "zh-Hant": "距離{number}：約{metres}公尺",
      "vi": "Khoảng cách {number}: khoảng {metres} m",
      "fil": "Distansya {number}: humigit-kumulang {metres} m",
    ],
    "Scan your bathroom": [
      "es": "Escanee su baño",
      "zh-Hans": "扫描浴室",
      "zh-Hant": "掃描浴室",
      "vi": "Quét phòng tắm của bạn",
      "fil": "I-scan ang iyong banyo",
    ],
    "Move slowly and follow the camera guidance. Stay on a safe, clear path. Scan only this bathroom.": [
      "es": "Muévase despacio y siga las indicaciones de la cámara. Manténgase en un camino seguro y despejado. Escanee solo este baño.",
      "zh-Hans": "缓慢移动并按照相机指引操作。保持在安全、畅通的路线上。仅扫描这间浴室。",
      "zh-Hant": "緩慢移動並按照相機指引操作。保持在安全、暢通的路線上。僅掃描這間浴室。",
      "vi": "Di chuyển chậm và làm theo hướng dẫn của camera. Đi trên lối an toàn, thông thoáng. Chỉ quét phòng tắm này.",
      "fil": "Dahan-dahang kumilos at sundin ang gabay ng camera. Manatili sa ligtas at maluwag na daanan. Ang banyong ito lang ang i-scan.",
    ],
    "Cancel scan": [
      "es": "Cancelar escaneo",
      "zh-Hans": "取消扫描",
      "zh-Hant": "取消掃描",
      "vi": "Hủy quét",
      "fil": "Kanselahin ang pag-scan",
    ],
    "Finish scan": [
      "es": "Terminar escaneo",
      "zh-Hans": "完成扫描",
      "zh-Hant": "完成掃描",
      "vi": "Hoàn tất quét",
      "fil": "Tapusin ang pag-scan",
    ],
    "Preparing the simplified 3D room. You will review and confirm it next.": [
      "es": "Preparando el modelo 3D simplificado. A continuación podrá revisarlo y confirmarlo.",
      "zh-Hans": "正在生成简化的三维房间模型。接下来请查看并确认。",
      "zh-Hant": "正在建立簡化的三維房間模型。接下來請查看並確認。",
      "vi": "Đang chuẩn bị mô hình 3D đơn giản. Tiếp theo bạn sẽ xem và xác nhận.",
      "fil": "Inihahanda ang pinasimpleng 3D na silid. Susunod mo itong susuriin at kukumpirmahin.",
    ],
    "Move slowly from a safe position. Keep the camera facing walls, floor and fixtures. Do not walk backward or step over obstacles while looking at the screen.": [
      "es": "Muévase despacio desde una posición segura. Apunte la cámara a las paredes, el piso y los elementos del baño. No camine hacia atrás ni pase sobre obstáculos mientras mira la pantalla.",
      "zh-Hans": "从安全的位置缓慢移动。相机朝向墙壁、地面和设施。看屏幕时不要倒退行走或跨越障碍物。",
      "zh-Hant": "從安全的位置緩慢移動。相機朝向牆壁、地面和設施。看螢幕時不要倒退行走或跨越障礙物。",
      "vi": "Di chuyển chậm từ vị trí an toàn. Hướng camera vào tường, sàn và thiết bị. Không đi lùi hay bước qua vật cản khi nhìn màn hình.",
      "fil": "Dahan-dahang kumilos mula sa ligtas na posisyon. Itutok ang camera sa dingding, sahig at mga gamit. Huwag maglakad nang paatras o humakbang sa mga hadlang habang tumitingin sa screen.",
    ],
    "This captures an approximate arrangement of surfaces and points. Android does not automatically identify toilets, sinks or doors. You will review the model and identify what it shows.": [
      "es": "Esto captura una distribución aproximada de superficies y puntos. Android no identifica automáticamente inodoros, lavabos ni puertas. Usted revisará el modelo e identificará lo que muestra.",
      "zh-Hans": "此功能捕捉表面和采样点的大致布局。Android 不会自动识别马桶、洗手池或门。您需要查看模型并识别其中的物体。",
      "zh-Hant": "此功能擷取表面和取樣點的大致布局。Android 不會自動辨識馬桶、洗手台或門。您需要查看模型並辨識其中的物體。",
      "vi": "Tính năng này ghi lại bố cục gần đúng của các bề mặt và điểm. Android không tự nhận diện bồn cầu, bồn rửa hay cửa. Bạn sẽ xem mô hình và xác định các vật thể.",
      "fil": "Tinatantiya nito ang ayos ng mga ibabaw at punto. Hindi awtomatikong nakikilala ng Android ang inidoro, lababo o pinto. Susuriin mo ang modelo at tutukuyin ang ipinapakita nito.",
    ],
    "Safe at Home does not save or upload raw camera frames. The reviewed geometry stays in your encrypted case on this device. Backgrounding or exceeding three minutes cancels this scan.": [
      "es": "Safe at Home no guarda ni sube imágenes sin procesar de la cámara. La geometría revisada queda en su caso cifrado en este dispositivo. Pasar la aplicación a segundo plano o superar tres minutos cancela el escaneo.",
      "zh-Hans": "Safe at Home 不会保存或上传原始相机画面。查看后的几何模型保存在此设备上的加密档案中。切换到后台或超过三分钟将取消扫描。",
      "zh-Hant": "Safe at Home 不會儲存或上傳原始相機畫面。查看後的幾何模型保存在此裝置上的加密檔案中。切換到背景或超過三分鐘將取消掃描。",
      "vi": "Safe at Home không lưu hay tải lên khung hình camera gốc. Hình học đã xem nằm trong hồ sơ mã hóa trên thiết bị này. Chuyển ứng dụng sang nền hoặc quá ba phút sẽ hủy quét.",
      "fil": "Hindi nagse-save o nag-a-upload ang Safe at Home ng orihinal na mga frame ng camera. Nananatili ang nasuring hugis sa naka-encrypt na kaso sa device na ito. Makakansela ang pag-scan kapag lumipat sa background o lumampas sa tatlong minuto.",
    ],
    "This application runs on Google Play Services for AR (ARCore), which is provided by Google and governed by the Google Privacy Policy.": [
      "es": "Esta aplicación usa Google Play Services for AR (ARCore), proporcionado por Google y sujeto a Google Privacy Policy.",
      "zh-Hans": "本应用使用 Google 提供的 Google Play Services for AR (ARCore)，并受 Google Privacy Policy 约束。",
      "zh-Hant": "本應用程式使用 Google 提供的 Google Play Services for AR (ARCore)，並受 Google Privacy Policy 規範。",
      "vi": "Ứng dụng này dùng Google Play Services for AR (ARCore) do Google cung cấp và chịu sự điều chỉnh của Google Privacy Policy.",
      "fil": "Gumagamit ang app na ito ng Google Play Services for AR (ARCore), na ibinibigay ng Google at saklaw ng Google Privacy Policy.",
    ],
    "Start bathroom scan": [
      "es": "Iniciar escaneo del baño",
      "zh-Hans": "开始扫描浴室",
      "zh-Hant": "開始掃描浴室",
      "vi": "Bắt đầu quét phòng tắm",
      "fil": "Simulan ang pag-scan ng banyo",
    ],
    "Cancel": [
      "es": "Cancelar",
      "zh-Hans": "取消",
      "zh-Hant": "取消",
      "vi": "Hủy",
      "fil": "Kanselahin",
    ],
    "{surfaces} surfaces · {points} sampled points · {seconds}s remaining. Move slowly. Missing areas stay unknown.": [
      "es": "{surfaces} superficies · {points} puntos · quedan {seconds} s. Muévase despacio. Las áreas no capturadas siguen sin conocerse.",
      "zh-Hans": "{surfaces} 个表面 · {points} 个采样点 · 剩余 {seconds} 秒。缓慢移动。未扫描的区域仍属未知。",
      "zh-Hant": "{surfaces} 個表面 · {points} 個取樣點 · 剩餘 {seconds} 秒。緩慢移動。未掃描的區域仍屬未知。",
      "vi": "{surfaces} bề mặt · {points} điểm mẫu · còn {seconds} giây. Di chuyển chậm. Khu vực còn thiếu vẫn chưa xác định.",
      "fil": "{surfaces} ibabaw · {points} na punto · {seconds}s na lang. Dahan-dahang kumilos. Hindi pa alam ang mga bahaging hindi na-scan.",
    ],
    "Finding position. Move slowly in good light and avoid blank or reflective surfaces. {seconds}s remaining.": [
      "es": "Buscando posición. Muévase despacio con buena luz y evite superficies lisas o reflectantes. Quedan {seconds} s.",
      "zh-Hans": "正在定位。在光线充足处缓慢移动，避开空白或反光表面。剩余 {seconds} 秒。",
      "zh-Hant": "正在定位。在光線充足處緩慢移動，避開空白或反光表面。剩餘 {seconds} 秒。",
      "vi": "Đang tìm vị trí. Di chuyển chậm nơi đủ sáng, tránh bề mặt trống hoặc phản chiếu. Còn {seconds} giây.",
      "fil": "Hinahanap ang posisyon. Dahan-dahang kumilos sa maliwanag na lugar at iwasan ang walang detalye o makintab na ibabaw. {seconds}s na lang.",
    ],
    "Live bathroom camera view. Detected surfaces and sampled points are outlined.": [
      "es": "Vista de cámara del baño en directo. Se delinean las superficies y los puntos detectados.",
      "zh-Hans": "浴室实时相机画面。已标出检测到的表面和采样点。",
      "zh-Hant": "浴室即時相機畫面。已標出偵測到的表面和取樣點。",
      "vi": "Hình ảnh trực tiếp phòng tắm. Các bề mặt và điểm mẫu được đánh dấu.",
      "fil": "Live na tanaw ng camera sa banyo. May balangkas ang natukoy na mga ibabaw at punto.",
    ],
    "Bathroom scan": [
      "es": "Escaneo del baño",
      "zh-Hans": "浴室扫描",
      "zh-Hant": "浴室掃描",
      "vi": "Quét phòng tắm",
      "fil": "Pag-scan ng banyo",
    ],
    "Finding position. Move slowly while facing the bathroom.": [
      "es": "Buscando posición. Muévase despacio apuntando hacia el baño.",
      "zh-Hans": "正在定位。面向浴室缓慢移动。",
      "zh-Hant": "正在定位。面向浴室緩慢移動。",
      "vi": "Đang tìm vị trí. Di chuyển chậm, hướng về phòng tắm.",
      "fil": "Hinahanap ang posisyon. Dahan-dahang kumilos habang nakaharap sa banyo.",
    ],
    "Finish and review 3D scan": [
      "es": "Terminar y revisar escaneo 3D",
      "zh-Hans": "完成并查看三维扫描",
      "zh-Hant": "完成並查看三維掃描",
      "vi": "Hoàn tất và xem bản quét 3D",
      "fil": "Tapusin at suriin ang 3D scan",
    ],
  ]
}
