import Flutter
import ImageIO
import UIKit
import UniformTypeIdentifiers

/// Native JPEG composite for GPS-stamp photos. All work runs on one serial background queue inside an
/// autoreleasepool; only the reply goes back to the main queue.
///
/// Decode: CGImageSourceCreateThumbnailAtIndex with kCGImageSourceThumbnailMaxPixelSize = output long edge and
/// kCGImageSourceCreateThumbnailWithTransform (EXIF orientation applied, the full 48 MP is never decoded), then
/// extraRotation + mirror into a CGContext of exactly outW x outH, the stamp overlay on top, and one
/// CGImageDestination that writes the JPEG together with the EXIF / TIFF / GPS dictionaries (Orientation = 1).
public class CommunityFlutterStampCompositePlugin: NSObject, FlutterPlugin {
  static let queue = DispatchQueue(label: "community_flutter_stamp_composite", qos: .userInitiated)

  public static func register(with registrar: FlutterPluginRegistrar) {
    let channel = FlutterMethodChannel(name: "community_flutter_stamp_composite", binaryMessenger: registrar.messenger())
    registrar.addMethodCallDelegate(CommunityFlutterStampCompositePlugin(), channel: channel)
  }

  public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    let args = call.arguments as? [String: Any] ?? [:]
    let work: () throws -> Any
    switch call.method {
    case "orientedSize":
      guard let path = args["path"] as? String else { result(FlutterError(code: "COMPOSITE", message: "path is required", details: nil)); return }
      work = { try StampComposite.orientedSize(path) }
    case "mapSnapshot":
      // The stamp's mini-map (MapKit, MapSnapshot.swift): PNG bytes, or a COMPOSITE error (offline, refused).
      MapSnapshot.run(args) { outcome in
        let reply: Any
        switch outcome {
        case .success(let png): reply = FlutterStandardTypedData(bytes: png)
        case .failure(let e): reply = e.flutterError
        }
        DispatchQueue.main.async { result(reply) }
      }
      return
    case "shutterSound":
      // AVCapturePhotoOutput already plays the system shutter sound on iOS (and Japan / Korea require it): nothing to add.
      result(nil); return
    case "composite":
      guard args["src"] is String, args["out"] is String, args["outWidth"] is NSNumber, args["outHeight"] is NSNumber else {
        result(FlutterError(code: "COMPOSITE", message: "src, out, outWidth and outHeight are required", details: nil)); return
      }
      work = { try StampComposite(args).run() }
    default:
      result(FlutterMethodNotImplemented); return
    }
    Self.queue.async {
      let reply: Any = autoreleasepool {
        do { return try work() } catch let e as StampError { return e.flutterError } catch { return StampError.composite("\(error)").flutterError }
      }
      DispatchQueue.main.async { result(reply) }
    }
  }
}

enum StampError: Error {
  case notFound(String), oom(String), composite(String)

  var flutterError: FlutterError {
    switch self {
    case .notFound(let m): return FlutterError(code: "NOT_FOUND", message: m, details: nil)
    case .oom(let m): return FlutterError(code: "OOM", message: m, details: nil)
    case .composite(let m): return FlutterError(code: "COMPOSITE", message: m, details: nil)
    }
  }
}

/// A memory failure inside one attempt (allocation returned nil) — retried once at half the cap.
private struct MemoryFailure: Error { let what: String }

final class StampComposite {
  let src: String, out: String, outW: Int, outH: Int, mirror: Bool, extraRotation: Int
  let overlay: Data?, overlayW: Int, overlayH: Int, overlayLeft: Int, overlayTop: Int, quality: Int
  let exif: [String: Any]?
  var debugFailAttempts: Int

  init(_ a: [String: Any]) {
    func int(_ k: String, _ d: Int = 0) -> Int { (a[k] as? NSNumber)?.intValue ?? d }
    src = a["src"] as! String; out = a["out"] as! String
    outW = int("outWidth"); outH = int("outHeight")
    mirror = a["mirror"] as? Bool ?? false
    extraRotation = int("extraRotation")
    overlay = (a["overlayRgba"] as? FlutterStandardTypedData)?.data
    overlayW = int("overlayWidth"); overlayH = int("overlayHeight"); overlayLeft = int("overlayLeft"); overlayTop = int("overlayTop")
    quality = int("quality", 90)
    exif = a["exif"] as? [String: Any]
    debugFailAttempts = int("debugFailAttempts")
  }

  static func orientedSize(_ path: String) throws -> [String: Any] {
    guard FileManager.default.fileExists(atPath: path) else { throw StampError.notFound("source not found: \(path)") }
    guard let s = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil),
          let p = CGImageSourceCopyPropertiesAtIndex(s, 0, nil) as? [CFString: Any],
          let w = (p[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue, let h = (p[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue
    else { throw StampError.composite("cannot read \(path)") }
    let o = (p[kCGImagePropertyOrientation] as? NSNumber)?.intValue ?? 1
    let (ow, oh) = StampTransform.orientedSize(o, w, h)
    return ["width": ow, "height": oh, "orientation": o, "storedWidth": w, "storedHeight": h]
  }

  func run() throws -> [String: Any] {
    guard FileManager.default.fileExists(atPath: src) else { throw StampError.notFound("source not found: \(src)") }
    guard outW > 0, outH > 0 else { throw StampError.composite("bad output size \(outW)x\(outH)") }
    guard StampTransform.normalizeRotation(extraRotation) != nil else { throw StampError.composite("extraRotation must be 0/90/180/270") }
    if let o = overlay, o.count != overlayW * overlayH * 4 {
      throw StampError.composite("overlay is \(o.count) bytes, expected \(overlayW)x\(overlayH)x4")
    }
    let t0 = CFAbsoluteTimeGetCurrent()
    do {
      do {
        return try attempt(outW, outH, downscaled: false, t0: t0)
      } catch let first as MemoryFailure {
        try? FileManager.default.removeItem(atPath: out)
        let (w2, h2) = StampTransform.outputSize(outW, outH, cap: max(outW, outH) / 2, extraRotation: 0)
        do {
          return try attempt(w2, h2, downscaled: true, t0: t0)
        } catch let second as MemoryFailure {
          throw StampError.oom("out of memory: \(first.what) at \(outW)x\(outH), \(second.what) at \(w2)x\(h2)")
        }
      }
    } catch {
      try? FileManager.default.removeItem(atPath: out)
      throw error
    }
  }

  private func attempt(_ ow: Int, _ oh: Int, downscaled: Bool, t0: Double) throws -> [String: Any] {
    if debugFailAttempts > 0 { debugFailAttempts -= 1; throw MemoryFailure(what: "debugFailAttempts") }
    guard let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: src) as CFURL, nil) else {
      throw StampError.composite("cannot open \(src)")
    }
    let oriented = try Self.orientedSize(src)
    // decode at the size where the upright source COVERS the output (== the output long edge when the ratios match)
    let decodeLong = StampTransform.coverDecodeLongEdge(orientedW: oriented["width"] as! Int, orientedH: oriented["height"] as! Int,
                                                        extraRotation: extraRotation, outW: ow, outH: oh)
    let opts: [CFString: Any] = [
      kCGImageSourceCreateThumbnailFromImageAlways: true,
      kCGImageSourceCreateThumbnailWithTransform: true,
      kCGImageSourceThumbnailMaxPixelSize: decodeLong,
      kCGImageSourceShouldCacheImmediately: true,
    ]
    guard let img = CGImageSourceCreateThumbnailAtIndex(source, 0, opts as CFDictionary) else {
      throw StampError.composite("cannot decode \(src)")
    }
    let t1 = CFAbsoluteTimeGetCurrent()
    let space: CGColorSpace = (img.colorSpace?.model == .rgb ? img.colorSpace : nil) ?? CGColorSpace(name: CGColorSpace.sRGB)!
    guard let ctx = CGContext(data: nil, width: ow, height: oh, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
      throw MemoryFailure(what: "CGContext")
    }
    ctx.interpolationQuality = .high
    // y-down output space
    ctx.translateBy(x: 0, y: CGFloat(oh))
    ctx.scaleBy(x: 1, y: -1)
    // the thumbnail is already EXIF-oriented: only crop + extraRotation + mirror + scale remain
    let m = StampTransform.build(exifOrientation: 1, extraRotation: extraRotation, mirror: mirror,
                                 srcW: img.width, srcH: img.height, outW: ow, outH: oh)
    ctx.saveGState()
    ctx.concatenate(CGAffineTransform(a: m.a, b: m.c, c: m.b, d: m.d, tx: m.tx, ty: m.ty))
    drawUpright(ctx, img, w: img.width, h: img.height)
    ctx.restoreGState()
    if let bytes = overlay, overlayW > 0, overlayH > 0 {
      guard let provider = CGDataProvider(data: bytes as CFData),
            let ov = CGImage(width: overlayW, height: overlayH, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: overlayW * 4,
                             space: CGColorSpace(name: CGColorSpace.sRGB)!,
                             bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                             provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
      else { throw StampError.composite("bad overlay") }
      let f = CGFloat(ow) / CGFloat(outW)
      ctx.saveGState()
      ctx.translateBy(x: CGFloat(overlayLeft) * f, y: CGFloat(overlayTop) * f)
      ctx.scaleBy(x: f, y: f)
      drawUpright(ctx, ov, w: overlayW, h: overlayH)
      ctx.restoreGState()
    }
    guard let composed = ctx.makeImage() else { throw MemoryFailure(what: "makeImage") }
    let t2 = CFAbsoluteTimeGetCurrent()
    guard let dest = CGImageDestinationCreateWithURL(URL(fileURLWithPath: out) as CFURL, UTType.jpeg.identifier as CFString, 1, nil) else {
      throw StampError.composite("cannot create \(out)")
    }
    var props = metadata()
    props[kCGImageDestinationLossyCompressionQuality] = Double(min(100, max(1, quality))) / 100
    CGImageDestinationAddImage(dest, composed, props as CFDictionary)
    guard CGImageDestinationFinalize(dest) else { throw StampError.composite("JPEG encode failed") }
    let t3 = CFAbsoluteTimeGetCurrent()
    // ImageIO keeps GPS seconds at 0.01"; rewrite lat/lon at 1e-7" in place (header bytes only, no re-encode)
    if let e = exif, let lat = (e["lat"] as? NSNumber)?.doubleValue, let lon = (e["lon"] as? NSNumber)?.doubleValue {
      let url = URL(fileURLWithPath: out)
      if let bytes = try? Data(contentsOf: url), let patched = ExifGpsPatch.patch(bytes, lat: lat, lon: lon) {
        do { try patched.write(to: url, options: .atomic) } catch { throw StampError.composite("EXIF GPS write failed: \(error)") }
      }
    }
    let t4 = CFAbsoluteTimeGetCurrent()
    return ["width": ow, "height": oh, "decodeMode": "imageio-thumbnail", "inSampleSize": 0,
            "decodeMs": (t1 - t0) * 1000, "drawMs": (t2 - t1) * 1000, "encodeMs": (t3 - t2) * 1000, "exifMs": (t4 - t3) * 1000,
            "totalMs": (t4 - t0) * 1000, "downscaledForMemory": downscaled]
  }

  static func utc(_ pattern: String) -> DateFormatter {
    let f = DateFormatter()
    f.locale = Locale(identifier: "en_US_POSIX"); f.timeZone = TimeZone(identifier: "UTC"); f.dateFormat = pattern
    return f
  }

  /// In a y-down user space, draw `img` with its row 0 at y = 0 (CGContext.draw itself is y-up).
  private func drawUpright(_ ctx: CGContext, _ img: CGImage, w: Int, h: Int) {
    ctx.translateBy(x: 0, y: CGFloat(h))
    ctx.scaleBy(x: 1, y: -1)
    ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
  }

  /// EXIF / TIFF / GPS written by the same CGImageDestination that encodes the pixels. nil exif = Orientation only.
  private func metadata() -> [CFString: Any] {
    var props: [CFString: Any] = [kCGImagePropertyOrientation: 1]
    var tiff: [CFString: Any] = [kCGImagePropertyTIFFOrientation: 1]
    guard let e = exif else { props[kCGImagePropertyTIFFDictionary] = tiff; return props }
    func str(_ k: String) -> String? { e[k] as? String }
    func num(_ k: String) -> Double? { (e[k] as? NSNumber)?.doubleValue }
    var ex: [CFString: Any] = [:]
    if let t = str("capturedLocal") {
      ex[kCGImagePropertyExifDateTimeOriginal] = t; ex[kCGImagePropertyExifDateTimeDigitized] = t; tiff[kCGImagePropertyTIFFDateTime] = t
    }
    if let o = str("utcOffset") {
      ex[kCGImagePropertyExifOffsetTimeOriginal] = o; ex[kCGImagePropertyExifOffsetTime] = o; ex[kCGImagePropertyExifOffsetTimeDigitized] = o
    }
    if let c = str("userComment") { ex[kCGImagePropertyExifUserComment] = c }
    if let v = str("make") { tiff[kCGImagePropertyTIFFMake] = v }
    if let v = str("model") { tiff[kCGImagePropertyTIFFModel] = v }
    if let v = str("software") { tiff[kCGImagePropertyTIFFSoftware] = v }
    var gps: [CFString: Any] = [:]
    if let lat = num("lat"), let lon = num("lon") {
      gps[kCGImagePropertyGPSLatitude] = abs(lat); gps[kCGImagePropertyGPSLatitudeRef] = lat >= 0 ? "N" : "S"
      gps[kCGImagePropertyGPSLongitude] = abs(lon); gps[kCGImagePropertyGPSLongitudeRef] = lon >= 0 ? "E" : "W"
    }
    if let alt = num("altitude") { gps[kCGImagePropertyGPSAltitude] = abs(alt); gps[kCGImagePropertyGPSAltitudeRef] = alt < 0 ? 1 : 0 }
    if let acc = num("accuracyMeters") { gps[kCGImagePropertyGPSHPositioningError] = acc }
    if let ms = (e["gpsUtcMillis"] as? NSNumber)?.doubleValue {
      let date = Date(timeIntervalSince1970: ms / 1000)
      gps[kCGImagePropertyGPSDateStamp] = Self.utc("yyyy:MM:dd").string(from: date)
      gps[kCGImagePropertyGPSTimeStamp] = Self.utc("HH:mm:ss").string(from: date)
    }
    props[kCGImagePropertyTIFFDictionary] = tiff
    if !ex.isEmpty { props[kCGImagePropertyExifDictionary] = ex }
    if !gps.isEmpty { props[kCGImagePropertyGPSDictionary] = gps }
    return props
  }
}
