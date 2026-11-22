import Foundation

/// `x' = a*x + b*y + tx`, `y' = c*x + d*y + ty` in image coordinates (origin top-left, y down).
/// Pure Swift (Foundation only) so it compiles and is tested on its own; mirrors StampTransform.kt and geometry.dart.
struct StampAffine: Equatable {
  var a, b, c, d, tx, ty: Double

  static let identity = StampAffine(a: 1, b: 0, c: 0, d: 1, tx: 0, ty: 0)

  func mapX(_ x: Double, _ y: Double) -> Double { a * x + b * y + tx }
  func mapY(_ x: Double, _ y: Double) -> Double { c * x + d * y + ty }

  /// `self` first, then `next`.
  func then(_ n: StampAffine) -> StampAffine {
    StampAffine(a: n.a * a + n.b * c, b: n.a * b + n.b * d, c: n.c * a + n.d * c, d: n.c * b + n.d * d,
                tx: n.a * tx + n.b * ty + n.tx, ty: n.c * tx + n.d * ty + n.ty)
  }
}

/// Final transform = EXIF orientation, then extra rotation (clockwise), then mirror (horizontal flip), then scale.
enum StampTransform {
  static func swapsAxes(_ o: Int) -> Bool { (5...8).contains(o) }

  /// nil when `deg` is not a multiple of 90.
  static func normalizeRotation(_ deg: Int) -> Int? {
    guard deg % 90 == 0 else { return nil }
    return ((deg % 360) + 360) % 360
  }

  static func orientedSize(_ o: Int, _ w: Int, _ h: Int) -> (Int, Int) { swapsAxes(o) ? (h, w) : (w, h) }

  /// Same rule as Dart `StampGeometry.outputSize` (used natively only for the half-cap memory retry).
  static func outputSize(_ w0: Int, _ h0: Int, cap: Int, extraRotation: Int) -> (Int, Int) {
    var w = w0, h = h0
    let long = max(w, h)
    if long > cap {
      let s = Double(cap) / Double(long)
      if w >= h { w = cap; h = max(1, Int((Double(h0) * s).rounded())) } else { h = cap; w = max(1, Int((Double(w0) * s).rounded())) }
    }
    return (normalizeRotation(extraRotation) ?? 0) % 180 == 90 ? (h, w) : (w, h)
  }

  static func exifStep(_ o: Int, _ w: Double, _ h: Double) -> StampAffine {
    switch o {
    case 2: return StampAffine(a: -1, b: 0, c: 0, d: 1, tx: w, ty: 0)
    case 3: return StampAffine(a: -1, b: 0, c: 0, d: -1, tx: w, ty: h)
    case 4: return StampAffine(a: 1, b: 0, c: 0, d: -1, tx: 0, ty: h)
    case 5: return StampAffine(a: 0, b: 1, c: 1, d: 0, tx: 0, ty: 0)
    case 6: return StampAffine(a: 0, b: -1, c: 1, d: 0, tx: h, ty: 0)
    case 7: return StampAffine(a: 0, b: -1, c: -1, d: 0, tx: h, ty: w)
    case 8: return StampAffine(a: 0, b: 1, c: -1, d: 0, tx: 0, ty: w)
    default: return .identity
    }
  }

  static func rotationStep(_ deg: Int, _ w: Double, _ h: Double) -> StampAffine {
    switch normalizeRotation(deg) ?? 0 {
    case 90: return StampAffine(a: 0, b: -1, c: 1, d: 0, tx: h, ty: 0)
    case 180: return StampAffine(a: -1, b: 0, c: 0, d: -1, tx: w, ty: h)
    case 270: return StampAffine(a: 0, b: 1, c: -1, d: 0, tx: 0, ty: w)
    default: return .identity
    }
  }

  static func rotatedSize(_ o: Int, _ extra: Int, _ w: Int, _ h: Int) -> (Int, Int) {
    let (uw, uh) = orientedSize(o, w, h)
    return (normalizeRotation(extra) ?? 0) % 180 == 90 ? (uh, uw) : (uw, uh)
  }

  /// Cover + centre-crop of the upright source: (left, top, width, height) in upright pixels. Same rule as
  /// StampTransform.kt / geometry.dart (and BoxFit.cover + Alignment.center in the Dart fallback).
  static func coverCrop(exifOrientation o: Int, extraRotation: Int, srcW: Int, srcH: Int, outW: Int, outH: Int)
    -> (left: Double, top: Double, width: Double, height: Double)
  {
    let (uw, uh) = orientedSize(o, srcW, srcH)
    let rotated = (normalizeRotation(extraRotation) ?? 0) % 180 == 90
    let dw = Double(rotated ? outH : outW), dh = Double(rotated ? outW : outH)
    if dw / dh > Double(uw) / Double(uh) {
      let ch = Double(uw) * dh / dw
      return (0, (Double(uh) - ch) / 2, Double(uw), ch)
    }
    let cw = Double(uh) * dw / dh
    return ((Double(uw) - cw) / 2, 0, cw, Double(uh))
  }

  /// Stored source pixel coordinates -> output pixel coordinates:
  /// EXIF orientation -> centre crop (cover) -> extra rotation -> scale -> mirror.
  static func build(exifOrientation o: Int, extraRotation: Int, mirror: Bool, srcW: Int, srcH: Int, outW: Int, outH: Int) -> StampAffine {
    let c = coverCrop(exifOrientation: o, extraRotation: extraRotation, srcW: srcW, srcH: srcH, outW: outW, outH: outH)
    let rotated = (normalizeRotation(extraRotation) ?? 0) % 180 == 90
    let rw = rotated ? c.height : c.width, rh = rotated ? c.width : c.height
    var m = exifStep(o, Double(srcW), Double(srcH))
      .then(StampAffine(a: 1, b: 0, c: 0, d: 1, tx: -c.left, ty: -c.top))
      .then(rotationStep(extraRotation, c.width, c.height))
      .then(StampAffine(a: Double(outW) / rw, b: 0, c: 0, d: Double(outH) / rh, tx: 0, ty: 0))
    if mirror { m = m.then(StampAffine(a: -1, b: 0, c: 0, d: 1, tx: Double(outW), ty: 0)) }
    return m
  }

  /// ImageIO thumbnail max-pixel-size that makes the upright source COVER the output (crop applied after decode).
  static func coverDecodeLongEdge(orientedW uw: Int, orientedH uh: Int, extraRotation: Int, outW: Int, outH: Int) -> Int {
    let rotated = (normalizeRotation(extraRotation) ?? 0) % 180 == 90
    let dw = Double(rotated ? outH : outW), dh = Double(rotated ? outW : outH)
    let cover = max(dw / Double(uw), dh / Double(uh))
    return Int((Double(max(uw, uh)) * cover).rounded(.up))
  }
}
