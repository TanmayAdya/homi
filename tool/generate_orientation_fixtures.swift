import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

let width = 80, height = 48
let colors: [[UInt8]] = [
  [220, 40, 40, 255], [20, 180, 70, 255],
  [25, 70, 220, 255], [230, 190, 20, 255]
]
let corners = [
  [0, 1, 2, 3], [1, 0, 3, 2], [3, 2, 1, 0], [2, 3, 0, 1],
  [0, 2, 1, 3], [2, 0, 3, 1], [3, 1, 2, 0], [1, 3, 0, 2]
]
var pixels = [UInt8](repeating: 0, count: width * height * 4)
for y in 0..<height {
  for x in 0..<width {
    let color = colors[(y >= height / 2 ? 2 : 0) + (x >= width / 2 ? 1 : 0)]
    for component in 0..<4 { pixels[(y * width + x) * 4 + component] = color[component] }
  }
}
guard let provider = CGDataProvider(data: Data(pixels) as CFData),
  let image = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
    bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
    bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue).union(.byteOrder32Big),
    provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
else { fatalError("Could not construct the manufactured source image") }

var output = """
import 'dart:convert';
import 'dart:typed_data';

class GeneratedOrientationPhoto {
  const GeneratedOrientationPhoto({required this.orientation, required this.width,
    required this.height, required this.expectedCorners, required this.encoded});
  final int orientation, width, height;
  final List<List<int>> expectedCorners;
  final String encoded;
  Uint8List get bytes => base64Decode(encoded);
}

const generatedOrientationPhotos = <GeneratedOrientationPhoto>[

"""
for orientation in 1...8 {
  let data = NSMutableData()
  guard let destination = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil)
  else { fatalError("JPEG encoder unavailable") }
  CGImageDestinationAddImage(destination, image, [
    kCGImageDestinationLossyCompressionQuality: 1.0,
    kCGImagePropertyOrientation: orientation,
    kCGImagePropertyGPSDictionary: [kCGImagePropertyGPSLatitude: 0.0,
      kCGImagePropertyGPSLongitude: 0.0, kCGImagePropertyGPSLatitudeRef: "N", kCGImagePropertyGPSLongitudeRef: "E"],
    kCGImagePropertyExifDictionary: [kCGImagePropertyExifDateTimeOriginal: "2000:01:01 00:00:00"]
  ] as CFDictionary)
  guard CGImageDestinationFinalize(destination), data.length < 96 * 1024,
    let source = CGImageSourceCreateWithData(data as CFData, nil),
    let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
    props[kCGImagePropertyOrientation] as? Int == orientation,
    props[kCGImagePropertyPixelWidth] as? Int == width,
    props[kCGImagePropertyPixelHeight] as? Int == height,
    props[kCGImagePropertyGPSDictionary] != nil
  else { fatalError("Manufactured JPEG metadata validation failed") }
  let expected = corners[orientation - 1].map { index in
    "[\(colors[index][0]), \(colors[index][1]), \(colors[index][2])]"
  }.joined(separator: ", ")
  let rotated = orientation >= 5
  output += "  GeneratedOrientationPhoto(orientation: \(orientation), width: \(rotated ? height : width), height: \(rotated ? width : height),\n"
  output += "    expectedCorners: [\(expected)],\n    encoded:\n"
  let encoded = Array((data as Data).base64EncodedString())
  for start in stride(from: 0, to: encoded.count, by: 100) {
    output += "      '\(String(encoded[start..<min(start + 100, encoded.count)]))'\n"
  }
  output += "  ),\n"
}
output += "];\n"
guard output.utf8.count < 192 * 1024,
  FileManager.default.fileExists(atPath: "integration_test/native_media_test.dart"),
  FileManager.default.fileExists(atPath: "pubspec.yaml")
else { fatalError("Run this bounded generator from the Safe at Home checkout") }
try output.write(toFile: "integration_test/support/generated_orientation_jpegs.dart", atomically: true, encoding: .utf8)
print("Generated 8 manufactured JPEG orientations; source 80x48; fictional metadata only")
