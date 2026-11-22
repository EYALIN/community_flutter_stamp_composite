import 'package:community_flutter_stamp_composite/community_flutter_stamp_composite.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

/// Same independent model as the Kotlin / Swift tests: EXIF 1..8, the extra rotation and the mirror rebuilt from
/// two array primitives (rotate 90° clockwise, flip horizontal) on a labelled grid.
class _Grid {
  _Grid(this.w, this.h, this.px);
  final int w, h;
  final List<int> px;
  int at(int x, int y) => px[y * w + x];
  _Grid rot90cw() => _Grid(h, w, List.generate(w * h, (i) => at(i ~/ h, h - 1 - (i % h))));
  _Grid flipH() => _Grid(w, h, List.generate(w * h, (i) => at(w - 1 - (i % w), i ~/ w)));
  _Grid rot(int n) {
    var g = this;
    for (var i = 0; i < n; i++) {
      g = g.rot90cw();
    }
    return g;
  }
}

_Grid _orient(_Grid g, int o) => switch (o) {
  1 => g,
  2 => g.flipH(),
  3 => g.rot(2),
  4 => g.rot(2).flipH(),
  5 => g.flipH().rot(3),
  6 => g.rot(1),
  7 => g.flipH().rot(1),
  8 => g.rot(3),
  _ => throw ArgumentError(o),
};

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('8 EXIF orientations x 4 rotations x mirror map every pixel onto the model', () {
    const w = 5, h = 3;
    final src = _Grid(w, h, List.generate(w * h, (i) => i));
    var checked = 0;
    for (var o = 1; o <= 8; o++) {
      for (final rot in [0, 90, 180, 270]) {
        for (final mirror in [false, true]) {
          var model = _orient(src, o).rot(rot ~/ 90);
          if (mirror) model = model.flipH();
          final r = StampGeometry.rotatedSize(o, rot, w, h);
          expect((r.width, r.height), (model.w, model.h), reason: 'dims o=$o rot=$rot');
          final t = StampGeometry.transform(
            exifOrientation: o, extraRotation: rot, mirror: mirror, srcW: w, srcH: h, outW: r.width, outH: r.height,
          );
          for (var y = 0; y < h; y++) {
            for (var x = 0; x < w; x++) {
              final ox = t.mapX(x + .5, y + .5).floor(), oy = t.mapY(x + .5, y + .5).floor();
              expect(model.at(ox, oy), src.at(x, y), reason: 'o=$o rot=$rot mirror=$mirror ($x,$y)->($ox,$oy)');
            }
          }
          // inverse round-trips and corners land on corners at 4x scale
          final s = StampGeometry.transform(
            exifOrientation: o, extraRotation: rot, mirror: mirror, srcW: w, srcH: h, outW: r.width * 4, outH: r.height * 4,
          );
          final inv = s.inverse();
          for (final (cx, cy) in [(0.0, 0.0), (5.0, 0.0), (0.0, 3.0), (5.0, 3.0)]) {
            final X = s.mapX(cx, cy), Y = s.mapY(cx, cy);
            expect([0.0, r.width * 4.0], contains(X));
            expect([0.0, r.height * 4.0], contains(Y));
            expect(inv.mapX(X, Y), closeTo(cx, 1e-9));
            expect(inv.mapY(X, Y), closeTo(cy, 1e-9));
          }
          checked++;
        }
      }
    }
    expect(checked, 64);
  });

  test('cover crop: square output from a 6x4 source, all orientations x rotations x mirror', () {
    const w = 6, h = 4;
    final src = _Grid(w, h, List.generate(w * h, (i) => i));
    _Grid square(_Grid g) {
      final n = g.w < g.h ? g.w : g.h, ox = (g.w - n) ~/ 2, oy = (g.h - n) ~/ 2;
      return _Grid(n, n, List.generate(n * n, (i) => g.at(ox + i % n, oy + i ~/ n)));
    }

    for (var o = 1; o <= 8; o++) {
      for (final rot in [0, 90, 180, 270]) {
        for (final mirror in [false, true]) {
          var model = square(_orient(src, o)).rot(rot ~/ 90);
          if (mirror) model = model.flipH();
          final t = StampGeometry.transform(exifOrientation: o, extraRotation: rot, mirror: mirror, srcW: w, srcH: h, outW: 4, outH: 4);
          var inside = 0;
          for (var y = 0; y < h; y++) {
            for (var x = 0; x < w; x++) {
              final fx = t.mapX(x + .5, y + .5), fy = t.mapY(x + .5, y + .5);
              if (fx < 0 || fy < 0 || fx >= 4 || fy >= 4) continue;
              inside++;
              expect(model.at(fx.floor(), fy.floor()), src.at(x, y), reason: 'crop o=$o rot=$rot mirror=$mirror');
            }
          }
          expect(inside, 16);
        }
      }
    }
  });

  test('cover crop: 4000x3000 -> 2250x4000 rot 90 keeps a centred square square', () {
    final c = StampGeometry.coverCrop(exifOrientation: 1, extraRotation: 90, srcW: 4000, srcH: 3000, outW: 2250, outH: 4000);
    expect(c, (left: 0.0, top: 375.0, width: 4000.0, height: 2250.0));
    final t = StampGeometry.transform(exifOrientation: 1, extraRotation: 90, mirror: false, srcW: 4000, srcH: 3000, outW: 2250, outH: 4000);
    final xs = [t.mapX(1800, 1300), t.mapX(2200, 1700)], ys = [t.mapY(1800, 1300), t.mapY(2200, 1700)];
    expect((xs[0] - xs[1]).abs(), closeTo(400, 1e-9));
    expect((ys[0] - ys[1]).abs(), closeTo(400, 1e-9));
  });

  test('extraRotation 180 puts the stored bottom-right at the top-left', () {
    final t = StampGeometry.transform(exifOrientation: 1, extraRotation: 180, mirror: false, srcW: 30, srcH: 40, outW: 30, outH: 40);
    expect((t.mapX(30, 40), t.mapY(30, 40)), (0.0, 0.0));
  });

  test('outputSize rule', () {
    ({int width, int height}) o(int w, int h, int cap, [int rot = 0]) =>
        StampGeometry.outputSize(srcOrientedW: w, srcOrientedH: h, maxLongEdge: cap, extraRotation: rot);
    expect(o(4000, 3000, 4000), (width: 4000, height: 3000));
    expect(o(3000, 2250, 4000), (width: 3000, height: 2250));
    expect(o(8000, 6000, 4000), (width: 4000, height: 3000));
    expect(o(8000, 6000, 2000), (width: 2000, height: 1500));
    expect(o(8160, 6120, 4000), (width: 4000, height: 3000));
    expect(o(8000, 6000, 4000, 90), (width: 3000, height: 4000));
    expect(o(3000, 4000, 3000, 270), (width: 3000, height: 2250));
    expect(o(4001, 2251, 4000), (width: 4000, height: 2250));
    expect(o(4002, 2251, 4000), (width: 4000, height: 2250));
    expect(o(9000, 1, 4000), (width: 4000, height: 1));
    expect(() => o(4000, 3000, 4000, 45), throwsArgumentError);
    expect(() => o(0, 3000, 4000), throwsArgumentError);
  });

  test('channel wrappers send the method names and arguments', () async {
    final calls = <MethodCall>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
      CommunityFlutterStampComposite.channel,
      (call) async {
        calls.add(call);
        return call.method == 'orientedSize' ? {'width': 3000, 'height': 4000} : {'width': 1, 'height': 2};
      },
    );
    expect((await CommunityFlutterStampComposite.orientedSize('/a.jpg'))['height'], 4000);
    expect((await CommunityFlutterStampComposite.composite({'src': '/a.jpg'}))['height'], 2);
    expect(calls.map((c) => c.method), ['orientedSize', 'composite']);
    expect(calls.first.arguments, {'path': '/a.jpg'});
  });
}
