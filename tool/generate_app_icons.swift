#!/usr/bin/env swift
import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

enum Segment {
  case move(Double, Double), line(Double, Double)
  case curve(Double, Double, Double, Double, Double, Double)
  case close
}
let house: [Segment] = [
  .move(512, 210),
  .curve(500, 210, 490, 214, 481, 222),
  .line(230, 431),
  .curve(218, 441, 211, 455, 211, 470),
  .curve(211, 492, 230, 511, 252, 511),
  .line(276, 511), .line(276, 753),
  .curve(276, 786, 303, 813, 336, 813),
  .line(688, 813),
  .curve(721, 813, 748, 786, 748, 753),
  .line(748, 511), .line(772, 511),
  .curve(794, 511, 813, 492, 813, 470),
  .curve(813, 455, 806, 441, 794, 431),
  .line(543, 222),
  .curve(534, 214, 524, 210, 512, 210), .close,
]
let doorway: [Segment] = [
  .move(422, 813), .line(422, 649),
  .curve(422, 599, 462, 559, 512, 559),
  .curve(562, 559, 602, 599, 602, 649),
  .line(602, 813), .close,
]
let iconColorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
let teal = CGColor(colorSpace: iconColorSpace, components: [23 / 255, 78 / 255, 73 / 255, 1])!
let ivory = CGColor(colorSpace: iconColorSpace, components: [248 / 255, 245 / 255, 238 / 255, 1])!
func path(_ segments: [Segment]) -> CGPath {
  let result = CGMutablePath()
  for segment in segments {
    switch segment {
    case .move(let x, let y): result.move(to: CGPoint(x: x, y: y))
    case .line(let x, let y): result.addLine(to: CGPoint(x: x, y: y))
    case .curve(let a, let b, let c, let d, let x, let y):
      result.addCurve(to: CGPoint(x: x, y: y), control1: CGPoint(x: a, y: b), control2: CGPoint(x: c, y: d))
    case .close: result.closeSubpath()
    }
  }
  return result
}
func svgPath(_ segments: [Segment]) -> String {
  func n(_ value: Double) -> String { String(Int(value)) }
  return segments.map { segment in
    switch segment {
    case .move(let x, let y): return "M\(n(x)) \(n(y))"
    case .line(let x, let y): return "L\(n(x)) \(n(y))"
    case .curve(let a, let b, let c, let d, let x, let y):
      return "C\(n(a)) \(n(b)) \(n(c)) \(n(d)) \(n(x)) \(n(y))"
    case .close: return "Z"
    }
  }.joined(separator: " ")
}
func ensureParent(_ url: URL) throws {
  try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
}
func write(_ string: String, to url: URL) throws {
  try ensureParent(url)
  try string.write(to: url, atomically: true, encoding: .utf8)
}
func png(size: Int, to url: URL) throws {
  guard let context = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8,
    bytesPerRow: size * 4, space: iconColorSpace, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else {
    throw NSError(domain: "SafeAtHomeIcon", code: 1)
  }
  context.setFillColor(teal)
  context.fill(CGRect(x: 0, y: 0, width: size, height: size))
  context.translateBy(x: 0, y: CGFloat(size))
  context.scaleBy(x: CGFloat(size) / 1024, y: -CGFloat(size) / 1024)
  context.setFillColor(ivory); context.addPath(path(house)); context.fillPath()
  context.setFillColor(teal); context.addPath(path(doorway)); context.fillPath()
  guard let image = context.makeImage() else { throw NSError(domain: "SafeAtHomeIcon", code: 2) }
  try ensureParent(url)
  guard let output = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
    throw NSError(domain: "SafeAtHomeIcon", code: 3)
  }
  CGImageDestinationAddImage(output, image, nil)
  guard CGImageDestinationFinalize(output),
    let source = CGImageSourceCreateWithURL(url as CFURL, nil),
    let decoded = CGImageSourceCreateImageAtIndex(source, 0, nil),
    decoded.width == size, decoded.height == size,
    [.none, .noneSkipFirst, .noneSkipLast].contains(decoded.alphaInfo) else {
    throw NSError(domain: "SafeAtHomeIcon", code: 4)
  }
}
func main() throws {
  guard CommandLine.arguments.count == 3 else {
    throw NSError(domain: "Usage: swift generate_app_icons.swift OUTPUT_DIRECTORY IOS_CONTENTS_JSON", code: 1)
  }
  let output = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
  let catalog = URL(fileURLWithPath: CommandLine.arguments[2])
  let data = try Data(contentsOf: catalog)
  guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
    let entries = object["images"] as? [[String: String]] else {
    throw NSError(domain: "Invalid existing icon catalog", code: 1)
  }
  let svg = """
  <svg xmlns="http://www.w3.org/2000/svg" width="1024" height="1024" viewBox="0 0 1024 1024" role="img" aria-labelledby="title">
    <title id="title">Safe at Home house mark</title>
    <path fill="#174E49" d="M0 0H1024V1024H0Z"/>
    <path fill="#F8F5EE" d="\(svgPath(house))"/>
    <path fill="#174E49" d="\(svgPath(doorway))"/>
  </svg>
  """
  try write(svg + "\n", to: output.appendingPathComponent("safe-at-home-mark.svg"))
  var written = Set<String>()
  for entry in entries {
    guard let filename = entry["filename"], filename == (filename as NSString).lastPathComponent,
      let dimensions = entry["size"]?.split(separator: "x"), dimensions.count == 2,
      let width = Double(dimensions[0]), let height = Double(dimensions[1]), width == height,
      let scaleString = entry["scale"], scaleString.hasSuffix("x"),
      let scale = Double(scaleString.dropLast()), scale >= 1, scale <= 3,
      width * scale >= 1, width * scale <= 1024, (width * scale).rounded() == width * scale else {
      throw NSError(domain: "Unsupported existing icon entry", code: 1)
    }
    if written.insert(filename).inserted {
      try png(size: Int(width * scale), to: output.appendingPathComponent("ios/AppIcon.appiconset/\(filename)"))
    }
  }
  try ensureParent(output.appendingPathComponent("ios/AppIcon.appiconset/Contents.json"))
  try data.write(to: output.appendingPathComponent("ios/AppIcon.appiconset/Contents.json"))
  for (density, size) in [("mdpi", 48), ("hdpi", 72), ("xhdpi", 96), ("xxhdpi", 144), ("xxxhdpi", 192)] {
    try png(size: size, to: output.appendingPathComponent("android/mipmap-\(density)/ic_launcher.png"))
  }
  let adaptiveScale = 0.8
  let safeRadius = 1024.0 * 66 / 108 / 2
  for segment in house + doorway {
    let points: [(Double, Double)]
    switch segment {
    case .move(let x, let y), .line(let x, let y): points = [(x, y)]
    case .curve(let a, let b, let c, let d, let x, let y): points = [(a, b), (c, d), (x, y)]
    case .close: points = []
    }
    for (x, y) in points {
      guard hypot(x - 512, y - 512) * adaptiveScale < safeRadius else {
        throw NSError(domain: "Artwork exceeds Android adaptive safe circle", code: 1)
      }
    }
  }
  let foreground = """
  <?xml version="1.0" encoding="utf-8"?>
  <vector xmlns:android="http://schemas.android.com/apk/res/android"
      android:width="108dp" android:height="108dp"
      android:viewportWidth="1024" android:viewportHeight="1024">
      <group android:scaleX="0.8" android:scaleY="0.8"
          android:translateX="102.4" android:translateY="102.4">
          <path android:fillColor="#F8F5EE" android:fillType="evenOdd"
              android:pathData="\(svgPath(house)) \(svgPath(doorway))" />
      </group>
  </vector>
  """
  let adaptive = """
  <?xml version="1.0" encoding="utf-8"?>
  <adaptive-icon xmlns:android="http://schemas.android.com/apk/res/android">
      <background android:drawable="@color/safe_at_home_icon_background" />
      <foreground android:drawable="@drawable/ic_launcher_foreground" />
  </adaptive-icon>
  """
  let colors = """
  <?xml version="1.0" encoding="utf-8"?>
  <resources>
      <color name="safe_at_home_icon_background">#174E49</color>
  </resources>
  """
  try write(foreground + "\n", to: output.appendingPathComponent("android/drawable/ic_launcher_foreground.xml"))
  try write(adaptive + "\n", to: output.appendingPathComponent("android/mipmap-anydpi-v26/ic_launcher.xml"))
  try write(colors + "\n", to: output.appendingPathComponent("android/values/safe_at_home_icon_colors.xml"))
  for size in [20, 40, 60, 180, 1024] {
    try png(size: size, to: output.appendingPathComponent("preview-\(size).png"))
  }
  print("Generated \(written.count) exact existing iOS icon filenames, 5 Android sizes, adaptive XML, SVG and opaque previews in \(output.path)")
}
try main()
