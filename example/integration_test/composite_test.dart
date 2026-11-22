import 'dart:io';
import 'dart:ui' as ui;

import 'package:community_flutter_stamp_composite/community_flutter_stamp_composite.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import 'exif_reader.dart';

/// Stored-corner colours of the generated assets (tool/make_test_assets.py).
const _named = <String, List<int>>{
  'red': [230, 20, 20],
  'green': [20, 200, 20],
  'blue': [20, 20, 230],
  'yellow': [240, 230, 20],
  'grey': [128, 128, 128],
  'magenta': [255, 0, 255],
  'black': [0, 0, 0],
};

String _nearest(List<int> rgb) {
  var best = '', bestD = 1 << 30;
  _named.forEach((k, v) {
    final d = (rgb[0] - v[0]) * (rgb[0] - v[0]) + (rgb[1] - v[1]) * (rgb[1] - v[1]) + (rgb[2] - v[2]) * (rgb[2] - v[2]);
    if (d < bestD) {
      bestD = d;
      best = k;
    }
  });
  return best;
}

class _Decoded {
  _Decoded(this.width, this.height, this.rgba);
  final int width, height;
  final ByteData rgba;
  String at(int x, int y) {
    final o = (y * width + x) * 4;
    return _nearest([rgba.getUint8(o), rgba.getUint8(o + 1), rgba.getUint8(o + 2)]);
  }
}

Future<_Decoded> _decode(String path) async {
  final codec = await ui.instantiateImageCodec(await File(path).readAsBytes());
  final img = (await codec.getNextFrame()).image;
  final data = (await img.toByteData(format: ui.ImageByteFormat.rawRgba))!;
  final d = _Decoded(img.width, img.height, data);
  img.dispose();
  codec.dispose();
  return d;
}

late Directory _tmp;
var _squareAsset = false;
final _timings = <String>[];

Future<String> _asset(String name) async {
  final f = File('${_tmp.path}/$name');
  if (!f.existsSync()) await f.writeAsBytes((await rootBundle.load('assets/$name')).buffer.asUint8List());
  return f.path;
}

/// Which stored corner block a stored point is in (10% blocks), else grey.
String _storedColour(double x, double y, int sw, int sh) {
  if (x >= sw / 2 - 200 && x < sw / 2 + 200 && y >= sh / 2 - 200 && y < sh / 2 + 200 && _squareAsset) return 'black';
  final left = x < sw * .1, right = x > sw * .9, top = y < sh * .1, bottom = y > sh * .9;
  if (top && left) return 'red';
  if (top && right) return 'green';
  if (bottom && left) return 'blue';
  if (bottom && right) return 'yellow';
  return 'grey';
}

class _Run {
  _Run(this.result, this.out, this.outW, this.outH, this.transform, this.sw, this.sh, this.bandTop, this.bandH);
  final Map<String, Object?> result;
  final String out;
  final int outW, outH, sw, sh;
  final StampAffine transform;
  final int? bandTop, bandH;
}

/// orientedSize -> outputSize (Dart) -> overlay band rendered at output scale -> native composite.
Future<_Run> _composite(
  String asset, {
  int cap = 4000,
  ({int width, int height})? outSize,
  int rot = 0,
  bool mirror = false,
  bool band = true,
  Map<String, Object?>? exif,
  int debugFailAttempts = 0,
  String? label,
}) async {
  final src = await _asset(asset);
  final o = await CommunityFlutterStampComposite.orientedSize(src);
  final size = outSize ??
      StampGeometry.outputSize(
        srcOrientedW: o['width']! as int, srcOrientedH: o['height']! as int, maxLongEdge: cap, extraRotation: rot,
      );
  final out = '${_tmp.path}/out_${DateTime.now().microsecondsSinceEpoch}.jpg';
  final bandH = size.height ~/ 20, bandTop = size.height ~/ 2 - bandH ~/ 2;
  Uint8List? rgba;
  if (band) {
    rgba = Uint8List(size.width * bandH * 4);
    for (var i = 0; i < rgba.length; i += 4) {
      rgba[i] = 255;
      rgba[i + 2] = 255;
      rgba[i + 3] = 255; // opaque magenta (premultiplied == straight when opaque)
    }
  }
  final r = await CommunityFlutterStampComposite.composite({
    'src': src, 'out': out, 'outWidth': size.width, 'outHeight': size.height, 'mirror': mirror, 'extraRotation': rot,
    'overlayRgba': rgba, 'overlayWidth': band ? size.width : 0, 'overlayHeight': band ? bandH : 0, 'overlayLeft': 0,
    'overlayTop': band ? bandTop : 0, 'quality': 90, 'exif': exif, 'debugFailAttempts': debugFailAttempts,
  });
  final w = r['width']! as int, h = r['height']! as int;
  final t = StampGeometry.transform(
    exifOrientation: o['orientation']! as int, extraRotation: rot, mirror: mirror,
    srcW: o['storedWidth']! as int, srcH: o['storedHeight']! as int, outW: w, outH: h,
  );
  final line = '${label ?? asset} cap=$cap rot=$rot mirror=$mirror -> ${w}x$h ${r['decodeMode']} '
      'sample=${r['inSampleSize']} decode=${_ms(r['decodeMs'])} draw=${_ms(r['drawMs'])} '
      'encode=${_ms(r['encodeMs'])} exif=${_ms(r['exifMs'])} total=${_ms(r['totalMs'])} ms';
  _timings.add(line);
  // ignore: avoid_print
  print('STAMP_TIMING $line');
  final f = w / size.width;
  return _Run(r, out, w, h, t, o['storedWidth']! as int, o['storedHeight']! as int,
      band ? (bandTop * f).round() : null, band ? (bandH * f).round() : null);
}

String _ms(Object? v) => (v as num).toStringAsFixed(0);

/// Every output corner (sampled 3% inside) has the colour of the stored corner the Dart transform maps it from.
Future<_Decoded> _expectCornersAndBand(_Run run) async {
  final d = await _decode(run.out);
  expect((d.width, d.height), (run.outW, run.outH));
  final inv = run.transform.inverse();
  for (final (fx, fy) in [(.03, .03), (.97, .03), (.03, .97), (.97, .97)]) {
    final x = (run.outW * fx).floor(), y = (run.outH * fy).floor();
    final expected = _storedColour(inv.mapX(x + .5, y + .5), inv.mapY(x + .5, y + .5), run.sw, run.sh);
    expect(d.at(x, y), expected, reason: 'corner ($fx,$fy) of ${run.outW}x${run.outH}');
  }
  if (run.bandTop != null) {
    final mid = run.bandTop! + run.bandH! ~/ 2;
    for (final x in [2, run.outW ~/ 2, run.outW - 3]) {
      expect(d.at(x, mid), 'magenta', reason: 'overlay at ($x,$mid)');
    }
    expect(d.at(run.outW ~/ 2, run.bandTop! - 6), 'grey', reason: 'row above the overlay');
    expect(d.at(run.outW ~/ 2, run.bandTop! + run.bandH! + 6), 'grey', reason: 'row below the overlay');
  }
  return d;
}

Map<String, Object> _exifOf(String path) => readExif(File(path).readAsBytesSync());

const _fullExif = <String, Object?>{
  'lat': 32.0853123, 'lon': -34.7817689, 'altitude': 12.5, 'accuracyMeters': 4.25,
  'capturedLocal': '2026:11:01 14:03:07', 'utcOffset': '+05:30',
  'gpsUtcMillis': 1793521987000, // 2026-11-01T08:33:07Z
  'make': 'TestMaker', 'model': 'Test Model', 'software': 'Stamp test', 'userComment': 'stamp test',
};

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  final android = Platform.isAndroid;

  setUpAll(() async => _tmp = await Directory.systemTemp.createTemp('stamp_it'));
  tearDownAll(() async {
    // ignore: avoid_print
    print('STAMP_TIMING_SUMMARY\n${_timings.join('\n')}');
    await _tmp.delete(recursive: true);
  });

  testWidgets('orientedSize reads the EXIF-oriented size', (_) async {
    final o = await CommunityFlutterStampComposite.orientedSize(await _asset('src_12mp_o6.jpg'));
    expect((o['width'], o['height'], o['orientation'], o['storedWidth']), (3000, 4000, 6, 4000));
  });

  testWidgets('12 MP orientation 6, full EXIF, overlay', (_) async {
    final run = await _composite('src_12mp_o6.jpg', exif: _fullExif);
    expect((run.outW, run.outH), (3000, 4000));
    if (android) expect((run.result['decodeMode'], run.result['inSampleSize']), ('exact-sample', 1));
    final d = await _expectCornersAndBand(run);
    expect(d.at(10, 10), 'blue', reason: 'orientation 6: the stored bottom-left is the upright top-left');
    final x = _exifOf(run.out);
    expect(x['0:${0x0112}'], 1);
    expect(gpsCoord(x, lat: true)!, closeTo(32.0853123, 1e-6));
    expect(gpsCoord(x, lat: false)!, closeTo(-34.7817689, 1e-6));
    expect(x['gps:6'] as double, closeTo(12.5, 1e-3));
    expect(x['gps:31'] as double, closeTo(4.25, 1e-3));
    expect(x['gps:29'], '2026:11:01');
    expect(x['gps:7'], [8.0, 33.0, 7.0]);
    expect(x['exif:${0x9003}'], '2026:11:01 14:03:07');
    expect(x['exif:${0x9011}'], '+05:30');
    expect((x['0:${0x010F}'], x['0:${0x0110}'], x['0:${0x0131}']), ('TestMaker', 'Test Model', 'Stamp test'));
    expect(userComment(x), 'stamp test');
  });

  testWidgets('48 MP to 4000 with extraRotation 180 is upside down', (_) async {
    final run = await _composite('src_48mp_o1.jpg', rot: 180, exif: const {'lat': 1.5, 'lon': 2.5});
    expect((run.outW, run.outH), (4000, 3000));
    if (android) expect((run.result['decodeMode'], run.result['inSampleSize']), ('exact-sample', 2));
    final d = await _expectCornersAndBand(run);
    expect(d.at(10, 10), 'yellow', reason: '180: stored bottom-right now top-left');
    expect(d.at(run.outW - 10, run.outH - 10), 'red', reason: '180: stored top-left now bottom-right');
    expect(_exifOf(run.out)['0:${0x0112}'], 1);
  });

  testWidgets('orientation 3 + mirror, exif null strips the source GPS', (_) async {
    final run = await _composite('src_12mp_o3.jpg', mirror: true);
    expect((run.outW, run.outH), (3000, 4000));
    final d = await _expectCornersAndBand(run);
    // orientation 3: upright top-left = stored bottom-right (yellow), top-right = stored bottom-left (blue);
    // the mirror swaps them.
    expect(d.at(10, 10), 'blue');
    expect(d.at(run.outW - 10, 10), 'yellow');
    final x = _exifOf(run.out);
    expect(x['0:${0x0112}'], 1);
    expect(x.keys.where((k) => k.startsWith('gps:')), isEmpty);
    expect(gpsCoord(_exifOf(await _asset('src_12mp_o3.jpg')), lat: true), isNotNull, reason: 'the source does carry GPS');
  });

  testWidgets('stripes: 12 MP orientation 6 to cap 3000 with extraRotation 90', (_) async {
    final run = await _composite('src_12mp_o6.jpg', cap: 3000, rot: 90);
    expect((run.outW, run.outH), (3000, 2250));
    if (android) expect((run.result['decodeMode'], run.result['inSampleSize']), ('stripes', 1));
    await _expectCornersAndBand(run);
  });

  testWidgets('stripes: 48 MP to cap 3000, extraRotation 270 + mirror', (_) async {
    final run = await _composite('src_48mp_o1.jpg', cap: 3000, rot: 270, mirror: true);
    expect((run.outW, run.outH), (2250, 3000));
    if (android) expect((run.result['decodeMode'], run.result['inSampleSize']), ('stripes', 2));
    await _expectCornersAndBand(run);
  });

  testWidgets('cover crop: 4000x3000 -> 2250x4000 with extraRotation 90, a centred square stays square', (_) async {
    _squareAsset = true;
    try {
      final run = await _composite('src_12mp_o1_square.jpg', rot: 90, outSize: (width: 2250, height: 4000), band: false, label: 'crop 16:9');
      expect((run.outW, run.outH), (2250, 4000));
      if (android) expect(run.result['decodeMode'], 'stripes', reason: 'a crop never takes the exact-sample path');
      final d = await _expectCornersAndBand(run);
      // measure the black square along the centre row and column (it sits at the output centre)
      int extent(bool horizontal) {
        var n = 0;
        final len = horizontal ? d.width : d.height;
        for (var i = 0; i < len; i++) {
          final c = horizontal ? d.at(i, d.height ~/ 2 - 150) : d.at(d.width ~/ 2, i);
          if (c == 'black') n++;
        }
        return n;
      }
      expect(extent(true), inInclusiveRange(397, 403), reason: 'square width (no stretch)');
      expect(extent(false), inInclusiveRange(397, 403), reason: 'square height (no stretch)');
      expect(d.at(10, 10), 'grey', reason: 'the corner blocks (top/bottom 300 rows) were cropped away');
    } finally {
      _squareAsset = false;
    }
  });

  testWidgets('memory failure retries once at half the cap; twice -> OOM', (_) async {
    final run = await _composite('src_48mp_o1.jpg', debugFailAttempts: 1, label: 'oom-retry');
    expect(run.result['downscaledForMemory'], true);
    expect((run.outW, run.outH), (2000, 1500));
    await _expectCornersAndBand(run);
    await expectLater(
      _composite('src_48mp_o1.jpg', debugFailAttempts: 2, label: 'oom-fail'),
      throwsA(isA<PlatformException>().having((e) => e.code, 'code', 'OOM')),
    );
  });

  testWidgets('missing source -> NOT_FOUND', (_) async {
    await expectLater(
      CommunityFlutterStampComposite.composite({'src': '${_tmp.path}/nope.jpg', 'out': '${_tmp.path}/x.jpg', 'outWidth': 10, 'outHeight': 10}),
      throwsA(isA<PlatformException>().having((e) => e.code, 'code', 'NOT_FOUND')),
    );
    await expectLater(
      CommunityFlutterStampComposite.orientedSize('${_tmp.path}/nope.jpg'),
      throwsA(isA<PlatformException>().having((e) => e.code, 'code', 'NOT_FOUND')),
    );
  });

  testWidgets('timing (no budget, numbers only)', (_) async {
    for (var i = 0; i < 3; i++) {
      await _composite('src_48mp_o1.jpg', exif: _fullExif, label: 'T 48MP->4000 #$i');
      await _composite('src_12mp_o6.jpg', exif: _fullExif, label: 'T 12MP o6 1:1 #$i');
      await _composite('src_48mp_o1.jpg', cap: 3000, exif: _fullExif, label: 'T 48MP->3000 stripes #$i');
    }
  });
}
