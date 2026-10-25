import Flutter
import UIKit
import ImageIO
import UniformTypeIdentifiers
import PhotosUI

final class PrivateMediaPlatform {
  private static let worker = DispatchQueue(label: "safe_at_home.private_media", qos: .userInitiated)
  private static var picker: PrivatePhotoPicker?
  static func register(with registrar: FlutterPluginRegistrar) {
    PrivateAppCover.install()
    let channel = FlutterMethodChannel(name: "safe_at_home/private_media", binaryMessenger: registrar.messenger())
    channel.setMethodCallHandler { call, result in
      if call.method == "clearTemporaryMedia" {
        picker?.cancel(); picker = nil
      }
      if call.method == "pickPhoto" {
        guard picker == nil else { result(FlutterError(code: "PICKER_BUSY", message: "A photo picker is already open.", details: nil)); return }
        let delegate = PrivatePhotoPicker { value in picker = nil; result(value) }
        picker = delegate; delegate.present(); return
      }
      worker.async {
        do {
          let answer = try handle(call)
          DispatchQueue.main.async { result(answer) }
        } catch {
          DispatchQueue.main.async {
            result(FlutterError(code: "PRIVATE_MEDIA_FAILED", message: "Private media could not be prepared.", details: nil))
          }
        }
      }
    }
  }

  private enum Failure: Error { case invalid }
  private static func ownedURL(_ path: String) throws -> URL {
    let url = URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath()
    let root = URL(fileURLWithPath: NSHomeDirectory()).standardizedFileURL.resolvingSymlinksInPath()
    guard url.path.hasPrefix(root.path + "/"), !url.path.contains("/Documents/") else { throw Failure.invalid }
    return url
  }
  private static func protect(_ url: URL) throws {
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true,
      attributes: [.protectionKey: FileProtectionType.complete])
    try FileManager.default.setAttributes([.protectionKey: FileProtectionType.complete], ofItemAtPath: url.path)
    var resourceURL = url
    var values = URLResourceValues(); values.isExcludedFromBackup = true
    try resourceURL.setResourceValues(values)
  }
  private static func clearRawCopies() throws {
    let caches = try FileManager.default.url(for: .cachesDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
    for url in [caches.appendingPathComponent("sah-capture"),
      FileManager.default.temporaryDirectory.appendingPathComponent("camera/pictures")] {
      if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
    }
  }
  private static func rect(_ value: Any, width: Int, height: Int) throws -> CGRect {
    guard let a = value as? [Double], a.count == 4, a.allSatisfy({ $0.isFinite }),
      a[0] >= 0, a[1] >= 0, a[2] > 0, a[3] > 0,
      a[0] + a[2] <= 1.000001, a[1] + a[3] <= 1.000001 else { throw Failure.invalid }
    return CGRect(x: a[0] * Double(width), y: a[1] * Double(height),
      width: a[2] * Double(width), height: a[3] * Double(height))
  }
  private static func handle(_ call: FlutterMethodCall) throws -> Any? {
    if call.method == "clearSharedDraftCopy" { return nil }
    if call.method == "clearTemporaryMedia" {
      try clearRawCopies(); return nil
    }
    if call.method == "prepareCaptureStorage" {
      try clearRawCopies()
      try protect(URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true))
      let caches = try FileManager.default.url(for: .cachesDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
      try protect(caches); return nil
    }
    if call.method == "privateRootDirectory" {
      let base = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
        appropriateFor: nil, create: true).appendingPathComponent("sah-private", isDirectory: true)
      try protect(base); return base.path
    }
    guard let args = call.arguments as? [String: Any] else { throw Failure.invalid }
    if call.method == "preparePrivateDirectory" {
      guard let path = args["path"] as? String else { throw Failure.invalid }
      let url = try ownedURL(path); try protect(url); return url.path
    }
    guard call.method == "normalizeImage" || call.method == "editImage" else { throw Failure.invalid }
    let source: CGImageSource
    if call.method == "normalizeImage" {
      guard let path = args["path"] as? String else { throw Failure.invalid }
      let url = try ownedURL(path)
      let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
      guard size > 0, size <= 64 * 1024 * 1024,
        let decoded = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary)
        else { throw Failure.invalid }
      source = decoded
    } else {
      guard let bytes = args["bytes"] as? FlutterStandardTypedData, bytes.data.count <= 8 * 1024 * 1024,
        let decoded = CGImageSourceCreateWithData(bytes.data as CFData,
          [kCGImageSourceShouldCache: false] as CFDictionary) else { throw Failure.invalid }
      source = decoded
    }
    let type = CGImageSourceGetType(source) as String?
    let heif = type == UTType.heic.identifier || type == UTType.heif.identifier
    let count = CGImageSourceGetCount(source)
    guard type == UTType.jpeg.identifier || type == UTType.png.identifier || heif,
      count >= 1, count <= (heif ? 32 : 1) else { throw Failure.invalid }
    let index = heif ? CGImageSourceGetPrimaryImageIndex(source) : 0
    guard let props = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any],
      let width = props[kCGImagePropertyPixelWidth] as? Int,
      let height = props[kCGImagePropertyPixelHeight] as? Int,
      width > 0, height > 0, width <= 50000, height <= 50000,
      Int64(width) * Int64(height) <= 200_000_000 else { throw Failure.invalid }
    guard var image = CGImageSourceCreateThumbnailAtIndex(source, index, [
      kCGImageSourceCreateThumbnailFromImageAlways: true,
      kCGImageSourceCreateThumbnailWithTransform: true,
      kCGImageSourceThumbnailMaxPixelSize: 2048,
      kCGImageSourceShouldCacheImmediately: true
    ] as CFDictionary) else { throw Failure.invalid }
    let originalWidth = image.width; let originalHeight = image.height
    if let redactions = args["redactions"] as? [Any], !redactions.isEmpty {
      guard redactions.count <= 20 else { throw Failure.invalid }
      let rectangles = try redactions.map { try rect($0, width: originalWidth, height: originalHeight) }
      let format = UIGraphicsImageRendererFormat(); format.scale = 1; format.opaque = true
      let rendered = UIGraphicsImageRenderer(size: CGSize(width: originalWidth, height: originalHeight), format: format).image { context in
        UIImage(cgImage: image).draw(at: .zero)
        context.cgContext.setFillColor(UIColor.black.cgColor)
        rectangles.forEach { context.cgContext.fill($0.integral) }
      }
      guard let redacted = rendered.cgImage else { throw Failure.invalid }; image = redacted
    }
    if let crop = args["crop"], !(crop is NSNull) {
      let cropRect = try rect(crop, width: originalWidth, height: originalHeight).integral.intersection(
        CGRect(x: 0, y: 0, width: originalWidth, height: originalHeight))
      guard cropRect.width >= 16, cropRect.height >= 16, let cropped = image.cropping(to: cropRect)
        else { throw Failure.invalid }; image = cropped
    }
    let pixelFormat = UIGraphicsImageRendererFormat()
    pixelFormat.scale = 1; pixelFormat.opaque = true
    pixelFormat.preferredRange = .standard
    let pixelBounds = CGRect(x: 0, y: 0, width: image.width, height: image.height)
    let isolated = UIGraphicsImageRenderer(size: pixelBounds.size, format: pixelFormat).image { context in
      context.cgContext.setFillColor(UIColor.black.cgColor)
      context.cgContext.fill(pixelBounds)
      UIImage(cgImage: image).draw(in: pixelBounds)
    }
    guard let pixels = isolated.cgImage else { throw Failure.invalid }
    let data = NSMutableData()
    guard let dest = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil) else { throw Failure.invalid }
    CGImageDestinationAddImage(dest, pixels, [kCGImageDestinationLossyCompressionQuality: 0.85] as CFDictionary)
    guard CGImageDestinationFinalize(dest), data.length <= 8 * 1024 * 1024 else { throw Failure.invalid }
    let sanitized = try JPEGPrivacyFilter.stripMetadata(data as Data)
    return ["bytes": FlutterStandardTypedData(bytes: sanitized), "width": image.width, "height": image.height]
  }
}


enum JPEGPrivacyFilter {
  static let maximumBytes = 8 * 1024 * 1024
  private enum Failure: Error { case invalid }

  static func stripMetadata(_ data: Data) throws -> Data {
    guard data.count >= 4, data.count <= maximumBytes else { throw Failure.invalid }
    let bytes = [UInt8](data)
    guard bytes[0] == 0xff, bytes[1] == 0xd8 else { throw Failure.invalid }
    var output = Data([0xff, 0xd8])
    output.reserveCapacity(bytes.count)
    var offset = 2, segments = 0
    var sawScan = false
    while offset < bytes.count {
      segments += 1
      guard segments <= 4096, bytes[offset] == 0xff else { throw Failure.invalid }
      let start = offset
      while offset < bytes.count && bytes[offset] == 0xff { offset += 1 }
      guard offset < bytes.count else { throw Failure.invalid }
      let marker = bytes[offset]
      offset += 1
      if marker == 0xd9 {
        guard sawScan, offset == bytes.count else { throw Failure.invalid }
        output.append(contentsOf: bytes[start..<offset])
        return output
      }
      guard marker != 0 && marker != 1 && marker != 0xd8,
        !(0xd0...0xd7).contains(marker), offset + 2 <= bytes.count else { throw Failure.invalid }
      let length = Int(bytes[offset]) * 256 + Int(bytes[offset + 1])
      guard length >= 2, length <= bytes.count - offset else { throw Failure.invalid }
      let end = offset + length
      if marker != 0xe1 && marker != 0xed && marker != 0xfe {
        output.append(contentsOf: bytes[start..<end])
      }
      offset = end
      if marker == 0xda {
        sawScan = true
        let scanStart = offset
        while offset < bytes.count {
          if bytes[offset] != 0xff { offset += 1; continue }
          var nextOffset = offset + 1
          while nextOffset < bytes.count && bytes[nextOffset] == 0xff { nextOffset += 1 }
          guard nextOffset < bytes.count else { throw Failure.invalid }
          let next = bytes[nextOffset]
          if next == 0 || (0xd0...0xd7).contains(next) {
            offset = nextOffset + 1
          } else {
            break
          }
        }
        output.append(contentsOf: bytes[scanStart..<offset])
      }
    }
    throw Failure.invalid
  }
}


enum ProtectedPhotoCopy {
  static let maximumBytes = 64 * 1024 * 1024
  private enum Failure: Error { case invalid, cancelled }

  static func copy(from source: URL, to destination: URL, isCancelled: () -> Bool) throws {
    guard !isCancelled() else { throw Failure.cancelled }
    let manager = FileManager.default
    let size = try source.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
    guard size > 0, size <= maximumBytes,
      !manager.fileExists(atPath: destination.path) else { throw Failure.invalid }
    let input = try FileHandle(forReadingFrom: source)
    defer { try? input.close() }
    guard manager.createFile(atPath: destination.path, contents: nil,
      attributes: [.protectionKey: FileProtectionType.complete]) else { throw Failure.invalid }
    var succeeded = false
    defer { if !succeeded { try? manager.removeItem(at: destination) } }
    var protected = destination
    var values = URLResourceValues(); values.isExcludedFromBackup = true
    try protected.setResourceValues(values)
    let output = try FileHandle(forWritingTo: destination)
    defer { try? output.close() }
    var total = 0
    while true {
      guard !isCancelled() else { throw Failure.cancelled }
      let bytes = try input.read(upToCount: 256 * 1024) ?? Data()
      if bytes.isEmpty { break }
      guard bytes.count <= maximumBytes - total else { throw Failure.invalid }
      total += bytes.count
      try output.write(contentsOf: bytes)
    }
    guard total > 0, !isCancelled() else { throw Failure.cancelled }
    try output.synchronize()
    succeeded = true
  }
}


final class PrivatePhotoPicker: NSObject, PHPickerViewControllerDelegate {
  typealias FileLoader = (NSItemProvider, String, @escaping (URL?, Error?) -> Void) -> Progress
  private let callback: (Any?) -> Void
  private let timeout: TimeInterval
  private let loadFile: FileLoader
  private let lock = NSLock()
  private var cancelled = false
  private var completed = false
  private var loading = false
  private var loadProgress: Progress?
  private var deadline: DispatchWorkItem?
  private weak var controller: PHPickerViewController?
  init(timeout: TimeInterval = 60,
    loadFile: @escaping FileLoader = { provider, type, completion in
      provider.loadFileRepresentation(forTypeIdentifier: type, completionHandler: completion)
    }, finish: @escaping (Any?) -> Void) {
    self.timeout = timeout; self.loadFile = loadFile; self.callback = finish
  }
  private var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancelled }
  private func cancelLoad() {
    lock.lock(); cancelled = true; lock.unlock()
    loadProgress?.cancel(); loadProgress = nil
  }
  private func finish(_ value: Any?) {
    guard !completed else { return }; completed = true
    deadline?.cancel(); deadline = nil; loadProgress = nil
    callback(value)
  }
  func cancel() {
    cancelLoad()
    controller?.dismiss(animated: false); finish(nil)
  }
  func present() {
    guard let window = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene })
      .flatMap({ $0.windows }).first(where: { $0.isKeyWindow }), var presenter = window.rootViewController else {
      finish(FlutterError(code: "PICKER_UNAVAILABLE", message: "Photo picker is unavailable.", details: nil)); return
    }
    while let shown = presenter.presentedViewController { presenter = shown }
    var configuration = PHPickerConfiguration(photoLibrary: .shared())
    configuration.filter = .images; configuration.selectionLimit = 1
    configuration.preferredAssetRepresentationMode = .current
    let picker = PHPickerViewController(configuration: configuration)
    picker.delegate = self; controller = picker; presenter.present(picker, animated: true)
  }
  func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
    let provider = results.first?.itemProvider
    picker.dismiss(animated: true) { [weak self] in
      guard let self, !self.completed, !self.isCancelled else { return }
      guard let provider else { self.finish(nil); return }
      self.importPhoto(from: provider)
    }
  }
  func importPhoto(from provider: NSItemProvider) {
    guard !completed && !loading else { return }
    guard let type = provider.registeredTypeIdentifiers.first(where: { UTType($0)?.conforms(to: .image) == true }) else {
      finish(FlutterError(code: "PHOTO_UNSUPPORTED", message: "Choose a still image.", details: nil)); return
    }
    loading = true
    let deadline = DispatchWorkItem { [weak self] in
      guard let self, !self.completed else { return }
      self.cancelLoad()
      self.finish(FlutterError(code: "PHOTO_IMPORT_TIMEOUT", message: "The photo import timed out. Try again when the photo is available on this device.", details: nil))
    }
    self.deadline = deadline
    DispatchQueue.main.asyncAfter(deadline: .now() + timeout, execute: deadline)
    loadProgress = loadFile(provider, type) { [weak self] url, _ in
      guard let self else { return }
      var ownedCopy: URL?
      do {
        guard !self.isCancelled else { return }
        guard let url = url else { throw NSError(domain: "photo", code: 1) }
        let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard size > 0, size <= 64 * 1024 * 1024 else { throw NSError(domain: "photo", code: 2) }
        let folder = try FileManager.default.url(for: .cachesDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
          .appendingPathComponent("sah-capture", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true,
          attributes: [.protectionKey: FileProtectionType.complete])
        var protected = folder; var values = URLResourceValues(); values.isExcludedFromBackup = true
        try protected.setResourceValues(values)
        let copy = folder.appendingPathComponent(UUID().uuidString).appendingPathExtension(url.pathExtension)
        ownedCopy = copy
        try ProtectedPhotoCopy.copy(from: url, to: copy, isCancelled: { self.isCancelled })
        if self.isCancelled { try? FileManager.default.removeItem(at: copy); return }
        DispatchQueue.main.async {
          if self.isCancelled { try? FileManager.default.removeItem(at: copy); return }
          self.finish(copy.path)
        }
      } catch {
        if let ownedCopy { try? FileManager.default.removeItem(at: ownedCopy) }
        DispatchQueue.main.async { self.finish(FlutterError(code: "PHOTO_IMPORT_FAILED", message: "The photo could not be imported.", details: nil)) }
      }
    }
  }
}


private enum PrivateAppCover {
  private static var tokens: [NSObjectProtocol] = []
  private static let tag = 20731022
  static func install() {
    guard tokens.isEmpty else { return }
    for name in [UIApplication.willResignActiveNotification, UIApplication.didEnterBackgroundNotification,
                 UIScene.willDeactivateNotification, UIScene.didEnterBackgroundNotification] {
      tokens.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { _ in cover() })
    }
    for name in [UIApplication.didBecomeActiveNotification, UIScene.didActivateNotification] {
      tokens.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { _ in uncover() })
    }
  }
  private static var windows: [UIWindow] {
    UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.flatMap { $0.windows }
  }
  private static func cover() {
    for window in windows where window.viewWithTag(tag) == nil {
      let cover = UIView(frame: window.bounds); cover.tag = tag
      cover.backgroundColor = UIColor(red: 0.97, green: 0.98, blue: 0.97, alpha: 1)
      cover.autoresizingMask = [.flexibleWidth, .flexibleHeight]
      cover.isAccessibilityElement = true; cover.accessibilityLabel = "Safe at Home"
      cover.accessibilityViewIsModal = true
      window.addSubview(cover)
    }
  }
  private static func uncover() {
    for window in windows { window.viewWithTag(tag)?.removeFromSuperview() }
  }
}
