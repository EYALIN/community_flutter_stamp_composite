import Foundation

/// ImageIO stores GPSLatitude / GPSLongitude seconds as n/100 (0.01" = up to ~2.8e-6 degrees off). This rewrites the
/// two 3-RATIONAL values IN PLACE inside the JPEG's Exif APP1 (same byte size, pixels untouched) as
/// deg/1, min/1, sec*10^7/10^7 — the precision Android's ExifInterface.setLatLong writes.
/// Pure Foundation so the standalone test compiles it.
enum ExifGpsPatch {
  /// Returns the patched bytes, or nil when the file has no Exif GPS latitude/longitude to patch.
  static func patch(_ jpeg: Data, lat: Double, lon: Double) -> Data? {
    var d = [UInt8](jpeg)
    guard d.count > 4, d[0] == 0xFF, d[1] == 0xD8 else { return nil }
    var p = 2
    while p + 4 <= d.count, d[p] == 0xFF {
      let marker = d[p + 1]
      let len = Int(d[p + 2]) << 8 | Int(d[p + 3])
      if marker == 0xDA { break }
      if marker == 0xE1, p + 10 <= d.count, d[p + 4] == 0x45, d[p + 5] == 0x78, d[p + 6] == 0x69, d[p + 7] == 0x66 {
        return patchTiff(&d, base: p + 10, end: p + 2 + len, lat: lat, lon: lon) ? Data(d) : nil
      }
      p += 2 + len
    }
    return nil
  }

  private static func patchTiff(_ d: inout [UInt8], base: Int, end: Int, lat: Double, lon: Double) -> Bool {
    guard base + 8 <= end, end <= d.count else { return false }
    let little = d[base] == 0x49
    func u16(_ o: Int) -> Int { little ? Int(d[base + o]) | Int(d[base + o + 1]) << 8 : Int(d[base + o]) << 8 | Int(d[base + o + 1]) }
    func u32(_ o: Int) -> Int {
      let b = (0..<4).map { Int(d[base + o + $0]) }
      return little ? b[0] | b[1] << 8 | b[2] << 16 | b[3] << 24 : b[0] << 24 | b[1] << 16 | b[2] << 8 | b[3]
    }
    func put32(_ o: Int, _ v: UInt32) {
      let bytes: [UInt8] = little
        ? [UInt8(v & 0xFF), UInt8(v >> 8 & 0xFF), UInt8(v >> 16 & 0xFF), UInt8(v >> 24)]
        : [UInt8(v >> 24), UInt8(v >> 16 & 0xFF), UInt8(v >> 8 & 0xFF), UInt8(v & 0xFF)]
      for i in 0..<4 { d[base + o + i] = bytes[i] }
    }
    let size = end - base
    func entries(_ ifd: Int) -> [(tag: Int, type: Int, count: Int, valueAt: Int)] {
      guard ifd + 2 <= size else { return [] }
      let n = u16(ifd)
      return (0..<n).compactMap { i in
        let e = ifd + 2 + i * 12
        guard e + 12 <= size else { return nil }
        return (u16(e), u16(e + 2), u32(e + 4), e + 8)
      }
    }
    guard let gpsEntry = entries(u32(4)).first(where: { $0.tag == 0x8825 }) else { return false }
    let gps = u32(gpsEntry.valueAt)
    var patched = 0
    for e in entries(gps) where (e.tag == 2 || e.tag == 4) && e.type == 5 && e.count == 3 {
      let off = u32(e.valueAt)
      guard off + 24 <= size else { continue }
      let v = abs(e.tag == 2 ? lat : lon)
      let deg = floor(v), minutes = floor((v - deg) * 60)
      var sec = ((v - deg) * 60 - minutes) * 60
      sec = max(0, min(sec, 59.9999999))
      let parts: [(UInt32, UInt32)] = [(UInt32(deg), 1), (UInt32(minutes), 1), (UInt32((sec * 1e7).rounded()), 10_000_000)]
      for (i, (n, den)) in parts.enumerated() { put32(off + i * 8, n); put32(off + i * 8 + 4, den) }
      patched += 1
    }
    return patched == 2
  }
}
