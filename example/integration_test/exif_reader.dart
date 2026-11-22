import 'dart:typed_data';

/// Minimal, independent EXIF reader for the tests (JPEG APP1 -> TIFF IFD0 + Exif IFD + GPS IFD).
/// Returns tag -> value: ASCII as String, SHORT/LONG as int (or `List<int>`), RATIONAL as double (or `List<double>`),
/// UNDEFINED as Uint8List. Keys are prefixed: '0:' IFD0, 'exif:' Exif IFD, 'gps:' GPS IFD.
Map<String, Object> readExif(Uint8List jpeg) {
  final out = <String, Object>{};
  var p = 2;
  while (p + 4 < jpeg.length && jpeg[p] == 0xFF) {
    final marker = jpeg[p + 1];
    final len = (jpeg[p + 2] << 8) | jpeg[p + 3];
    if (marker == 0xE1 && String.fromCharCodes(jpeg.sublist(p + 4, p + 8)) == 'Exif') {
      _tiff(ByteData.sublistView(jpeg, p + 10, p + 2 + len), out);
      return out;
    }
    if (marker == 0xDA) break;
    p += 2 + len;
  }
  return out;
}

void _tiff(ByteData t, Map<String, Object> out) {
  final e = t.getUint16(0) == 0x4949 ? Endian.little : Endian.big;
  int u16(int o) => t.getUint16(o, e);
  int u32(int o) => t.getUint32(o, e);
  void ifd(int off, String prefix) {
    final n = u16(off);
    for (var i = 0; i < n; i++) {
      final en = off + 2 + i * 12;
      final tag = u16(en), type = u16(en + 2), count = u32(en + 4);
      const sizes = {1: 1, 2: 1, 3: 2, 4: 4, 5: 8, 7: 1, 9: 4, 10: 8};
      final size = (sizes[type] ?? 1) * count;
      final vo = size <= 4 ? en + 8 : u32(en + 8);
      Object v;
      switch (type) {
        case 2:
          var s = String.fromCharCodes(List.generate(count, (k) => t.getUint8(vo + k)));
          final z = s.indexOf('\u0000');
          if (z >= 0) s = s.substring(0, z);
          v = s;
        case 3:
          final l = List.generate(count, (k) => u16(vo + k * 2));
          v = l.length == 1 ? l.first : l;
        case 4:
          final l = List.generate(count, (k) => u32(vo + k * 4));
          v = l.length == 1 ? l.first : l;
        case 5 || 10:
          final l = List.generate(count, (k) {
            final a = type == 5 ? u32(vo + k * 8) : t.getInt32(vo + k * 8, e);
            final b = type == 5 ? u32(vo + k * 8 + 4) : t.getInt32(vo + k * 8 + 4, e);
            return b == 0 ? 0.0 : a / b;
          });
          v = l.length == 1 ? l.first : l;
        default:
          v = Uint8List.fromList(List.generate(count, (k) => t.getUint8(vo + k)));
      }
      out['$prefix$tag'] = v;
      if (prefix == '0:' && tag == 0x8769) ifd(v as int, 'exif:');
      if (prefix == '0:' && tag == 0x8825) ifd(v as int, 'gps:');
    }
  }

  ifd(u32(4), '0:');
}

/// Signed decimal degrees from the GPS IFD, or null.
double? gpsCoord(Map<String, Object> x, {required bool lat}) {
  final v = x[lat ? 'gps:2' : 'gps:4'];
  final ref = x[lat ? 'gps:1' : 'gps:3'];
  if (v is! List<double> || ref is! String) return null;
  final d = v[0] + v[1] / 60 + v[2] / 3600;
  return (ref == 'S' || ref == 'W') ? -d : d;
}

/// UserComment without its 8-byte character-code prefix.
String? userComment(Map<String, Object> x) {
  final v = x['exif:${0x9286}'];
  if (v is String) return v;
  if (v is! Uint8List) return null;
  final hasPrefix = v.length >= 8 && const ['ASCII', 'UNICODE', 'JIS', '\u0000'].any((p) => String.fromCharCodes(v.sublist(0, 8)).startsWith(p));
  final body = hasPrefix ? v.sublist(8) : v;
  return String.fromCharCodes(body).replaceAll('\u0000', '');
}
