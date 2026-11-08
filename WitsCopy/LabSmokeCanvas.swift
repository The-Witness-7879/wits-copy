import AppKit
import ImageIO

/// Corner-marked canvases for isolated smoke only. Not used by the normal app.
enum LabSmokeCanvas {
  static func png(pixels: NSSize) -> Data? {
    guard let image = cgImage(pixels: pixels, frame: 0) else { return nil }
    let data = NSMutableData()
    guard let dest = CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil) else {
      return nil
    }
    CGImageDestinationAddImage(dest, image, nil)
    guard CGImageDestinationFinalize(dest) else { return nil }
    return data as Data
  }

  static func gif(pixels: NSSize, frames: Int) -> Data? {
    let count = max(frames, 1)
    let data = NSMutableData()
    guard let dest = CGImageDestinationCreateWithData(
      data,
      "com.compuserve.gif" as CFString,
      count,
      nil
    ) else { return nil }
    CGImageDestinationSetProperties(dest, [
      kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]
    ] as CFDictionary)
    for index in 0..<count {
      guard let image = cgImage(pixels: pixels, frame: index) else { return nil }
      CGImageDestinationAddImage(dest, image, [
        kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: 0.4]
      ] as CFDictionary)
    }
    guard CGImageDestinationFinalize(dest) else { return nil }
    return data as Data
  }

  private static var directory: URL {
    // Honor the isolated runner's explicit scratch root. Foundation may cache a
    // different per-user temporary directory even when TMPDIR was supplied.
    let root = ProcessInfo.processInfo.environment["TMPDIR"].flatMap { path -> URL? in
      guard path.hasPrefix("/") else { return nil }
      return URL(fileURLWithPath: path, isDirectory: true)
    } ?? FileManager.default.temporaryDirectory
    return root.appending(
      path: "witscopy-smoke-\(ProcessInfo.processInfo.processIdentifier)",
      directoryHint: .isDirectory
    )
  }

  static func cleanup() {
    try? FileManager.default.removeItem(at: directory)
  }

  static func write(_ data: Data, name: String) -> URL? {
    let dir = directory
    do {
      try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
      let url = dir.appending(path: name)
      try data.write(to: url, options: .atomic)
      return url
    } catch {
      return nil
    }
  }

  private static func cgImage(pixels: NSSize, frame: Int) -> CGImage? {
    let width = Int(pixels.width)
    let height = Int(pixels.height)
    guard width > 0, height > 0,
          let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: width,
            pixelsHigh: height,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
          ),
          let bytes = rep.bitmapData else {
      return nil
    }
    let row = rep.bytesPerRow
    let block = min(80, min(width, height) / 4)
    for y in 0..<height {
      for x in 0..<width {
        let offset = y * row + x * 4
        let color = sample(x: x, y: y, width: width, height: height, block: block, frame: frame)
        bytes[offset] = color.0
        bytes[offset + 1] = color.1
        bytes[offset + 2] = color.2
        bytes[offset + 3] = 255
      }
    }
    return rep.cgImage
  }

  private static func sample(
    x: Int,
    y: Int,
    width: Int,
    height: Int,
    block: Int,
    frame: Int
  ) -> (UInt8, UInt8, UInt8) {
    let shift = frame * max(block / 2, 1)
    let sx = (x + shift) % max(width, 1)
    if sx < block && y < block { return (255, 16, 16) }
    if sx >= width - block && y < block { return (16, 255, 16) }
    if x < block && y >= height - block { return (16, 16, 255) }
    if x >= width - block && y >= height - block { return (255, 255, 16) }
    return (28, 28, 32)
  }
}
