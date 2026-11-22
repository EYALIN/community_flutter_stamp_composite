/// Pure-Dart mirror of the native orientation / size math (`StampTransform.kt`, `StampTransform.swift`).
/// No Flutter imports: unit-testable on the VM.
library;

import 'dart:math' as math;

/// `x' = a*x + b*y + tx`, `y' = c*x + d*y + ty` in image coordinates (origin top-left, y down).
class StampAffine {
  const StampAffine(this.a, this.b, this.c, this.d, this.tx, this.ty);

  static const identity = StampAffine(1, 0, 0, 1, 0, 0);

  final double a, b, c, d, tx, ty;

  double mapX(double x, double y) => a * x + b * y + tx;
  double mapY(double x, double y) => c * x + d * y + ty;

  /// `this` first, then [next].
  StampAffine then(StampAffine next) => StampAffine(
    next.a * a + next.b * c,
    next.a * b + next.b * d,
    next.c * a + next.d * c,
    next.c * b + next.d * d,
    next.a * tx + next.b * ty + next.tx,
    next.c * tx + next.d * ty + next.ty,
  );

  /// The inverse map (output -> stored source).
  StampAffine inverse() {
    final det = a * d - b * c;
    if (det == 0) throw StateError('singular transform');
    final ia = d / det, ib = -b / det, ic = -c / det, id = a / det;
    return StampAffine(ia, ib, ic, id, -(ia * tx + ib * ty), -(ic * tx + id * ty));
  }

  @override
  String toString() => 'StampAffine($a, $b, $c, $d, $tx, $ty)';
}

/// Final transform = EXIF orientation, then extra rotation (clockwise), then mirror (horizontal flip),
/// then scale to the output size.
abstract final class StampGeometry {
  static bool swapsAxes(int exifOrientation) => exifOrientation >= 5 && exifOrientation <= 8;

  static int normalizeRotation(int deg) {
    if (deg % 90 != 0) throw ArgumentError.value(deg, 'extraRotation', 'must be 0/90/180/270');
    return ((deg % 360) + 360) % 360;
  }

  /// Stored size -> upright (EXIF-oriented) size.
  static ({int width, int height}) orientedSize(int exifOrientation, int w, int h) =>
      swapsAxes(exifOrientation) ? (width: h, height: w) : (width: w, height: h);

  /// The output-size rule shared with native: long edge <= cap -> unchanged; else long edge = cap and the short
  /// edge = round(short * cap / long) (>= 1) — a long edge of cap * 2^k gives exactly source / 2^k. 90 / 270
  /// swap width and height.
  static ({int width, int height}) outputSize({
    required int srcOrientedW,
    required int srcOrientedH,
    required int maxLongEdge,
    required int extraRotation,
  }) {
    if (srcOrientedW <= 0 || srcOrientedH <= 0) throw ArgumentError('empty source ${srcOrientedW}x$srcOrientedH');
    if (maxLongEdge <= 0) throw ArgumentError.value(maxLongEdge, 'maxLongEdge', 'must be > 0');
    final rot = normalizeRotation(extraRotation);
    var w = srcOrientedW, h = srcOrientedH;
    final long = math.max(w, h);
    if (long > maxLongEdge) {
      final s = maxLongEdge / long;
      if (w >= h) {
        w = maxLongEdge;
        h = math.max(1, (srcOrientedH * s).round());
      } else {
        h = maxLongEdge;
        w = math.max(1, (srcOrientedW * s).round());
      }
    }
    return rot % 180 == 90 ? (width: h, height: w) : (width: w, height: h);
  }

  /// Stored w x h -> upright box.
  static StampAffine exifStep(int o, double w, double h) => switch (o) {
    2 => StampAffine(-1, 0, 0, 1, w, 0),
    3 => StampAffine(-1, 0, 0, -1, w, h),
    4 => StampAffine(1, 0, 0, -1, 0, h),
    5 => const StampAffine(0, 1, 1, 0, 0, 0),
    6 => StampAffine(0, -1, 1, 0, h, 0),
    7 => StampAffine(0, -1, -1, 0, h, w),
    8 => StampAffine(0, 1, -1, 0, 0, w),
    _ => StampAffine.identity,
  };

  /// Clockwise rotation of a w x h box, result again at the origin.
  static StampAffine rotationStep(int deg, double w, double h) => switch (normalizeRotation(deg)) {
    90 => StampAffine(0, -1, 1, 0, h, 0),
    180 => StampAffine(-1, 0, 0, -1, w, h),
    270 => StampAffine(0, 1, -1, 0, 0, w),
    _ => StampAffine.identity,
  };

  /// Stored size after EXIF orientation and the extra rotation (before scaling).
  static ({int width, int height}) rotatedSize(int exifOrientation, int extraRotation, int srcW, int srcH) {
    final u = orientedSize(exifOrientation, srcW, srcH);
    return normalizeRotation(extraRotation) % 180 == 90 ? (width: u.height, height: u.width) : u;
  }

  /// Cover + centre-crop: the centred crop of the UPRIGHT source whose ratio equals the output's (rotated
  /// back to upright) — the source covers the output, the excess on the long side is cropped equally from both ends,
  /// never stretched. Same as applyBoxFit(BoxFit.cover) + Alignment.center in the Dart fallback compositor.
  static ({double left, double top, double width, double height}) coverCrop({
    required int exifOrientation,
    required int extraRotation,
    required int srcW,
    required int srcH,
    required int outW,
    required int outH,
  }) {
    final u = orientedSize(exifOrientation, srcW, srcH);
    final rotated = normalizeRotation(extraRotation) % 180 == 90;
    final dw = (rotated ? outH : outW).toDouble(), dh = (rotated ? outW : outH).toDouble();
    if (dw / dh > u.width / u.height) {
      final ch = u.width * dh / dw;
      return (left: 0, top: (u.height - ch) / 2, width: u.width.toDouble(), height: ch);
    }
    final cw = u.height * dw / dh;
    return (left: (u.width - cw) / 2, top: 0, width: cw, height: u.height.toDouble());
  }

  /// Stored source pixel coordinates -> output pixel coordinates:
  /// EXIF orientation -> centre crop (cover) -> extra rotation -> scale -> mirror.
  static StampAffine transform({
    required int exifOrientation,
    required int extraRotation,
    required bool mirror,
    required int srcW,
    required int srcH,
    required int outW,
    required int outH,
  }) {
    final c = coverCrop(
      exifOrientation: exifOrientation, extraRotation: extraRotation, srcW: srcW, srcH: srcH, outW: outW, outH: outH,
    );
    final rotated = normalizeRotation(extraRotation) % 180 == 90;
    final rw = rotated ? c.height : c.width, rh = rotated ? c.width : c.height;
    var m = exifStep(exifOrientation, srcW.toDouble(), srcH.toDouble())
        .then(StampAffine(1, 0, 0, 1, -c.left, -c.top))
        .then(rotationStep(extraRotation, c.width, c.height))
        .then(StampAffine(outW / rw, 0, 0, outH / rh, 0, 0));
    if (mirror) m = m.then(StampAffine(-1, 0, 0, 1, outW.toDouble(), 0));
    return m;
  }
}
