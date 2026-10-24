import Flutter
import UIKit
import ImageIO
import XCTest
import UniformTypeIdentifiers
@testable import Runner

@MainActor
class RunnerTests: XCTestCase {
  private func provider() -> NSItemProvider {
    NSItemProvider(item: Data([1, 2, 3]) as NSData, typeIdentifier: UTType.png.identifier)
  }

  private func source() throws -> URL {
    let file = FileManager.default.temporaryDirectory
      .appendingPathComponent("sah-picker-unit-" + UUID().uuidString).appendingPathExtension("png")
    try Data([1, 2, 3, 4]).write(to: file)
    return file
  }

  func testStalledImportTimesOutCancelsProviderAndIgnoresLateFile() async throws {
    let file = try source()
    defer { try? FileManager.default.removeItem(at: file) }
    let done = expectation(description: "import deadline")
    let progress = Progress(totalUnitCount: 1)
    var completion: ((URL?, Error?) -> Void)?
    var answers: [Any?] = []
    let picker = PrivatePhotoPicker(timeout: 0.03, loadFile: { _, _, callback in
      completion = callback; return progress
    }, finish: { value in answers.append(value); done.fulfill() })
    picker.importPhoto(from: provider())
    await fulfillment(of: [done], timeout: 1)
    XCTAssertTrue(progress.isCancelled)
    XCTAssertEqual((answers.first! as? FlutterError)?.code, "PHOTO_IMPORT_TIMEOUT")
    completion?(file, nil)
    picker.cancel()
    await Task.yield()
    XCTAssertEqual(answers.count, 1)
    XCTAssertEqual(try Data(contentsOf: file), Data([1, 2, 3, 4]))
  }

  func testExplicitCancellationCompletesOnceAndRetainsLibraryRepresentation() async throws {
    let file = try source()
    defer { try? FileManager.default.removeItem(at: file) }
    let progress = Progress(totalUnitCount: 1)
    var completion: ((URL?, Error?) -> Void)?
    var answers: [Any?] = []
    let picker = PrivatePhotoPicker(timeout: 1, loadFile: { _, _, callback in
      completion = callback; return progress
    }, finish: { answers.append($0) })
    picker.importPhoto(from: provider())
    picker.cancel()
    completion?(file, nil)
    picker.cancel()
    await Task.yield()
    XCTAssertTrue(progress.isCancelled)
    XCTAssertEqual(answers.count, 1)
    XCTAssertNil(answers[0])
    XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
  }

  func testSuccessfulImportReturnsPrivateCopyAndCancelsDeadline() async throws {
    let file = try source()
    defer { try? FileManager.default.removeItem(at: file) }
    let done = expectation(description: "import completion")
    var answers: [Any?] = []
    let picker = PrivatePhotoPicker(timeout: 0.05, loadFile: { _, _, callback in
      callback(file, nil); return Progress(totalUnitCount: 1)
    }, finish: { value in answers.append(value); done.fulfill() })
    picker.importPhoto(from: provider())
    await fulfillment(of: [done], timeout: 1)
    let path = try XCTUnwrap(answers.first! as? String)
    let copy = URL(fileURLWithPath: path)
    defer { try? FileManager.default.removeItem(at: copy) }
    XCTAssertNotEqual(copy.path, file.path)
    XCTAssertEqual(try Data(contentsOf: copy), try Data(contentsOf: file))
    let attributes = try FileManager.default.attributesOfItem(atPath: copy.path)
    let protection = attributes[.protectionKey] as? String
    #if targetEnvironment(simulator)
      if let protection { XCTAssertEqual(protection, FileProtectionType.complete.rawValue) }
    #else
      XCTAssertEqual(protection, FileProtectionType.complete.rawValue)
    #endif
    XCTAssertEqual(try copy.deletingLastPathComponent().resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup, true)
    try await Task.sleep(nanoseconds: 100_000_000)
    XCTAssertEqual(answers.count, 1)
    XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
    _ = picker
  }

  func testProtectedCopyHasCompleteProtectionBeforeFirstPhotoByte() throws {
    let file = try source()
    let copy = file.deletingLastPathComponent().appendingPathComponent("sah-protected-" + UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: file); try? FileManager.default.removeItem(at: copy) }
    try FileManager.default.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: file.path)
    var inspectedEmptyDestination = false
    try ProtectedPhotoCopy.copy(from: file, to: copy, isCancelled: {
      if !inspectedEmptyDestination, FileManager.default.fileExists(atPath: copy.path) {
        inspectedEmptyDestination = true
        do {
          let attributes = try FileManager.default.attributesOfItem(atPath: copy.path)
          XCTAssertEqual((attributes[.size] as? NSNumber)?.intValue, 0)
          let protection = attributes[.protectionKey] as? String
          #if targetEnvironment(simulator)
            if let protection { XCTAssertEqual(protection, FileProtectionType.complete.rawValue) }
          #else
            XCTAssertEqual(protection, FileProtectionType.complete.rawValue)
          #endif
          XCTAssertEqual(try copy.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup, true)
        } catch { XCTFail("Could not inspect the empty protected destination: \(error)") }
      }
      return false
    })
    XCTAssertTrue(inspectedEmptyDestination)
    XCTAssertEqual(try Data(contentsOf: copy), try Data(contentsOf: file))
    let sourceProtection = try FileManager.default.attributesOfItem(atPath: file.path)[.protectionKey] as? String
    #if targetEnvironment(simulator)
      if let sourceProtection { XCTAssertEqual(sourceProtection, FileProtectionType.completeUntilFirstUserAuthentication.rawValue) }
    #else
      XCTAssertEqual(sourceProtection, FileProtectionType.completeUntilFirstUserAuthentication.rawValue)
    #endif
  }

  func testProtectedCopyCancellationRemovesPartialDestinationAndPreservesSource() throws {
    let file = try source()
    let copy = file.deletingLastPathComponent().appendingPathComponent("sah-protected-" + UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: file); try? FileManager.default.removeItem(at: copy) }
    let bytes = Data(repeating: 17, count: 700 * 1024)
    try bytes.write(to: file)
    var cancelledAtByteCount: Int?
    XCTAssertThrowsError(try ProtectedPhotoCopy.copy(from: file, to: copy, isCancelled: {
      let attributes = try? FileManager.default.attributesOfItem(atPath: copy.path)
      let size = (attributes?[.size] as? NSNumber)?.intValue ?? 0
      if size > 0 { cancelledAtByteCount = size; return true }
      return false
    }))
    let partialCount = try XCTUnwrap(cancelledAtByteCount)
    XCTAssertGreaterThan(partialCount, 0)
    XCTAssertLessThan(partialCount, bytes.count)
    XCTAssertFalse(FileManager.default.fileExists(atPath: copy.path))
    XCTAssertEqual(try Data(contentsOf: file), bytes)
  }

  func testProtectedCopyRejectsOversizedInputAndExistingDestination() throws {
    let file = try source()
    let copy = file.deletingLastPathComponent().appendingPathComponent("sah-protected-" + UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: file); try? FileManager.default.removeItem(at: copy) }
    let existing = Data([9, 8, 7])
    try existing.write(to: copy)
    XCTAssertThrowsError(try ProtectedPhotoCopy.copy(from: file, to: copy, isCancelled: { false }))
    XCTAssertEqual(try Data(contentsOf: copy), existing)
    try FileManager.default.removeItem(at: copy)
    let handle = try FileHandle(forWritingTo: file)
    try handle.truncate(atOffset: UInt64(ProtectedPhotoCopy.maximumBytes + 1))
    try handle.close()
    XCTAssertThrowsError(try ProtectedPhotoCopy.copy(from: file, to: copy, isCancelled: { false }))
    XCTAssertFalse(FileManager.default.fileExists(atPath: copy.path))
  }

  func testJPEGPrivacyFilterPreservesEveryScanByteAndStripsLaterMetadata() throws {
    let app0: [UInt8] = [0xff, 0xe0, 0, 4, 1, 2]
    let exif: [UInt8] = [0xff, 0xe1, 0, 6, 69, 120, 105, 102]
    let sos: [UInt8] = [0xff, 0xda, 0, 2]
    let first: [UInt8] = [10, 0xff, 0, 0xe1, 11, 0xff, 0xff, 0xd0, 12]
    let iptc: [UInt8] = [0xff, 0xed, 0, 4, 3, 4]
    let table: [UInt8] = [0xff, 0xc4, 0, 3, 1]
    let second: [UInt8] = [20, 0xff, 0xff, 0, 21, 0xff, 0xd7, 22]
    let comment: [UInt8] = [0xff, 0xfe, 0, 3, 9]
    let head: [UInt8] = [0xff, 0xd8]
    let end: [UInt8] = [0xff, 0xd9]
    var inputBytes = head
    for part in [app0, exif, sos, first, iptc, table, sos, second, comment, end] { inputBytes.append(contentsOf: part) }
    var expectedBytes = head
    for part in [app0, sos, first, table, sos, second, end] { expectedBytes.append(contentsOf: part) }
    let input = Data(inputBytes), expected = Data(expectedBytes)
    XCTAssertEqual(try JPEGPrivacyFilter.stripMetadata(input), expected)
    XCTAssertEqual(try JPEGPrivacyFilter.stripMetadata(expected), expected)
  }

  func testJPEGPrivacyFilterRejectsMalformedTruncatedAndTrailingData() throws {
    let invalid: [[UInt8]] = [
      [], [0xff, 0xd8, 0xff, 0xd9],
      [0xff, 0xd8, 0xff, 0xe1, 0, 1],
      [0xff, 0xd8, 0xff, 0xe1, 0, 8, 1],
      [0xff, 0xd8, 0xff, 0, 0, 2],
      [0xff, 0xd8, 0xff, 0xda, 0, 2, 1, 0xff],
      [0xff, 0xd8, 0xff, 0xda, 0, 2, 1, 0xff, 0xd9, 0],
    ]
    for bytes in invalid { XCTAssertThrowsError(try JPEGPrivacyFilter.stripMetadata(Data(bytes))) }
    XCTAssertThrowsError(try JPEGPrivacyFilter.stripMetadata(
      Data(repeating: 0, count: JPEGPrivacyFilter.maximumBytes + 1)))
  }

  func testFreshImageIOEncoderMetadataIsInspectedAndRemoved() throws {
    let format = UIGraphicsImageRendererFormat()
    format.scale = 1; format.opaque = true; format.preferredRange = .standard
    let image = UIGraphicsImageRenderer(size: CGSize(width: 16, height: 16), format: format).image { context in
      context.cgContext.setFillColor(UIColor.systemTeal.cgColor)
      context.cgContext.fill(CGRect(x: 0, y: 0, width: 16, height: 16))
    }
    let data = NSMutableData()
    let destination = try XCTUnwrap(CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil))
    CGImageDestinationAddImage(destination, try XCTUnwrap(image.cgImage),
      [kCGImageDestinationLossyCompressionQuality: 0.85] as CFDictionary)
    XCTAssertTrue(CGImageDestinationFinalize(destination))
    let original = try XCTUnwrap(CGImageSourceCreateWithData(data as CFData, nil))
    let properties = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(original, 0, nil) as? [String: Any])
    print("LOCAL_FRESH_JPEG_METADATA_KEYS: " + properties.keys.sorted().joined(separator: ","))
    XCTAssertNil(properties[kCGImagePropertyGPSDictionary as String])
    let filtered = try JPEGPrivacyFilter.stripMetadata(data as Data)
    let source = try XCTUnwrap(CGImageSourceCreateWithData(filtered as CFData, nil))
    let retained = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any])
    XCTAssertNil(retained[kCGImagePropertyGPSDictionary as String])
    XCTAssertNil(retained[kCGImagePropertyExifDictionary as String])
    XCTAssertNil(retained[kCGImagePropertyIPTCDictionary as String])
    let decoded = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
    XCTAssertEqual(decoded.width, 16); XCTAssertEqual(decoded.height, 16)
  }
}
