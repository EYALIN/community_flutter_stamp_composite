// Standalone test for StampTransform.swift (no Xcode project needed): tool/test_swift_transform.sh compiles
// this file together with the source and runs it. Same independent grid model as the Kotlin and Dart tests.
import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

struct Grid {
  let w: Int, h: Int, px: [Int]
  func at(_ x: Int, _ y: Int) -> Int { px[y * w + x] }
  func rot90cw() -> Grid { Grid(w: h, h: w, px: (0..<(w * h)).map { i in at(i / h, h - 1 - (i % h)) }) }
  func flipH() -> Grid { Grid(w: w, h: h, px: (0..<(w * h)).map { i in at(w - 1 - (i % w), i / w) }) }
  func rot(_ n: Int) -> Grid { var g = self; for _ in 0..<n { g = g.rot90cw() }; return g }
}

func orient(_ g: Grid, _ o: Int) -> Grid {
  switch o {
  case 2: return g.flipH()
  case 3: return g.rot(2)
  case 4: return g.rot(2).flipH()
  case 5: return g.flipH().rot(3)
  case 6: return g.rot(1)
  case 7: return g.flipH().rot(1)
  case 8: return g.rot(3)
  default: return g
  }
}

var failures = 0, checks = 0
func check(_ ok: Bool, _ msg: @autoclosure () -> String) { checks += 1; if !ok { failures += 1; print("FAIL: \(msg())") } }

let w = 5, h = 3
let src = Grid(w: w, h: h, px: Array(0..<(w * h)))
for o in 1...8 { for rot in [0, 90, 180, 270] { for mirror in [false, true] {
  var model = orient(src, o).rot(rot / 90)
  if mirror { model = model.flipH() }
  let (rw, rh) = StampTransform.rotatedSize(o, rot, w, h)
  check(rw == model.w && rh == model.h, "dims o=\(o) rot=\(rot)")
  let t = StampTransform.build(exifOrientation: o, extraRotation: rot, mirror: mirror, srcW: w, srcH: h, outW: rw, outH: rh)
  for y in 0..<h { for x in 0..<w {
    let X = Int(floor(t.mapX(Double(x) + 0.5, Double(y) + 0.5))), Y = Int(floor(t.mapY(Double(x) + 0.5, Double(y) + 0.5)))
    check(model.at(X, Y) == src.at(x, y), "o=\(o) rot=\(rot) mirror=\(mirror) (\(x),\(y))->(\(X),\(Y))")
  } }
  let s = StampTransform.build(exifOrientation: o, extraRotation: rot, mirror: mirror, srcW: w, srcH: h, outW: rw * 4, outH: rh * 4)
  for (cx, cy) in [(0.0, 0.0), (5.0, 0.0), (0.0, 3.0), (5.0, 3.0)] {
    let X = s.mapX(cx, cy), Y = s.mapY(cx, cy)
    check((X == 0 || X == Double(rw * 4)) && (Y == 0 || Y == Double(rh * 4)), "corner o=\(o) rot=\(rot)")
  }
} } }

func square(_ g: Grid) -> Grid {
  let n = min(g.w, g.h), ox = (g.w - n) / 2, oy = (g.h - n) / 2
  return Grid(w: n, h: n, px: (0..<(n * n)).map { i in g.at(ox + i % n, oy + i / n) })
}
let cs = Grid(w: 6, h: 4, px: Array(0..<24))
for o in 1...8 { for rot in [0, 90, 180, 270] { for mirror in [false, true] {
  var model = square(orient(cs, o)).rot(rot / 90)
  if mirror { model = model.flipH() }
  let t = StampTransform.build(exifOrientation: o, extraRotation: rot, mirror: mirror, srcW: 6, srcH: 4, outW: 4, outH: 4)
  var inside = 0
  for y in 0..<4 { for x in 0..<6 {
    let fx = t.mapX(Double(x) + 0.5, Double(y) + 0.5), fy = t.mapY(Double(x) + 0.5, Double(y) + 0.5)
    if fx < 0 || fy < 0 || fx >= 4 || fy >= 4 { continue }
    inside += 1
    check(model.at(Int(floor(fx)), Int(floor(fy))) == cs.at(x, y), "crop o=\(o) rot=\(rot) mirror=\(mirror) (\(x),\(y))")
  } }
  check(inside == 16, "crop keeps 16 pixels o=\(o) rot=\(rot)")
} } }
let c169 = StampTransform.coverCrop(exifOrientation: 1, extraRotation: 90, srcW: 4000, srcH: 3000, outW: 2250, outH: 4000)
check(c169.left == 0 && c169.top == 375 && c169.width == 4000 && c169.height == 2250, "16:9 crop \(c169)")
let t169 = StampTransform.build(exifOrientation: 1, extraRotation: 90, mirror: false, srcW: 4000, srcH: 3000, outW: 2250, outH: 4000)
check(abs(abs(t169.mapX(1800, 1300) - t169.mapX(2200, 1700)) - 400) < 1e-9 && abs(abs(t169.mapY(1800, 1300) - t169.mapY(2200, 1700)) - 400) < 1e-9, "square stays square")
check(StampTransform.coverDecodeLongEdge(orientedW: 4000, orientedH: 3000, extraRotation: 90, outW: 2250, outH: 4000) == 4000, "cover decode long edge")
check(StampTransform.coverDecodeLongEdge(orientedW: 8000, orientedH: 6000, extraRotation: 0, outW: 4000, outH: 3000) == 4000, "matching ratio decodes at the output long edge")

let t180 = StampTransform.build(exifOrientation: 1, extraRotation: 180, mirror: false, srcW: 3000, srcH: 4000, outW: 3000, outH: 4000)
check(t180.mapX(3000, 4000) == 0 && t180.mapY(3000, 4000) == 0, "180 puts stored bottom-right at top-left")
for (inp, exp) in [((4000, 3000, 4000, 0), (4000, 3000)), ((3000, 2250, 4000, 0), (3000, 2250)), ((8000, 6000, 4000, 0), (4000, 3000)),
                   ((8160, 6120, 4000, 0), (4000, 3000)), ((8000, 6000, 4000, 90), (3000, 4000)), ((3000, 4000, 3000, 270), (3000, 2250)),
                   ((4001, 2251, 4000, 0), (4000, 2250)), ((4002, 2251, 4000, 0), (4000, 2250)), ((9000, 1, 4000, 0), (4000, 1))] {
  let r = StampTransform.outputSize(inp.0, inp.1, cap: inp.2, extraRotation: inp.3)
  check(r == exp, "outputSize \(inp) -> \(r), expected \(exp)")
}
// ExifGpsPatch: an ImageIO-written JPEG (0.01" seconds) patched to 1e-7" reads back within 1e-6 degrees through ImageIO (whose own reader rounds up to ~6e-7; the raw rationals are checked by the example integration test)
do {
  let ctx = CGContext(data: nil, width: 8, height: 8, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
  let img = ctx.makeImage()!
  let url = URL(fileURLWithPath: NSTemporaryDirectory() + "gps_patch_test.jpg")
  for (lat, lon) in [(32.0853123, -34.7817689), (-0.0000004, 179.9999999), (89.123456789, -0.5)] {
    let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil)!
    let gps: [CFString: Any] = [kCGImagePropertyGPSLatitude: abs(lat), kCGImagePropertyGPSLatitudeRef: lat >= 0 ? "N" : "S",
                                kCGImagePropertyGPSLongitude: abs(lon), kCGImagePropertyGPSLongitudeRef: lon >= 0 ? "E" : "W"]
    CGImageDestinationAddImage(dest, img, [kCGImagePropertyGPSDictionary: gps] as CFDictionary)
    _ = CGImageDestinationFinalize(dest)
    let patched = ExifGpsPatch.patch(try! Data(contentsOf: url), lat: lat, lon: lon)
    check(patched != nil, "patch found GPS")
    try! patched!.write(to: url)
    let p = CGImageSourceCopyPropertiesAtIndex(CGImageSourceCreateWithURL(url as CFURL, nil)!, 0, nil) as! [CFString: Any]
    let g = p[kCGImagePropertyGPSDictionary] as! [CFString: Any]
    let la = (g[kCGImagePropertyGPSLatitude] as! Double) * ((g[kCGImagePropertyGPSLatitudeRef] as! String) == "S" ? -1 : 1)
    let lo = (g[kCGImagePropertyGPSLongitude] as! Double) * ((g[kCGImagePropertyGPSLongitudeRef] as! String) == "W" ? -1 : 1)
    check(abs(la - lat) < 1e-6 && abs(lo - lon) < 1e-6, "gps patch \(lat),\(lon) -> \(la),\(lo)")
  }
  check(ExifGpsPatch.patch(Data([0xFF, 0xD8, 0xFF, 0xD9]), lat: 1, lon: 1) == nil, "no exif -> nil")
  try? FileManager.default.removeItem(at: url)
}

print("swift StampTransform: \(checks - failures)/\(checks) checks passed")
exit(failures == 0 ? 0 : 1)
