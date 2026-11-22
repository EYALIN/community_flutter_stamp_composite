/// Native JPEG composite for GPS-stamp photos (Android Kotlin, iOS Swift).
///
/// The wire API is map-based on purpose (an app can wrap it in its own typed request / result objects).
/// [StampGeometry] is the pure-Dart mirror of the native size / orientation math.
library;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

export 'src/geometry.dart';

abstract final class CommunityFlutterStampComposite {
  static const MethodChannel channel = MethodChannel('community_flutter_stamp_composite');

  /// Runs one composite on the native background worker.
  ///
  /// Arguments (the shared `StampCompositeRequest.toMap()`): `src`, `out`, `outWidth`, `outHeight` (required —
  /// the exact output size computed in Dart; native never re-derives it), `mirror`, `extraRotation` (0/90/180/270
  /// clockwise, after EXIF orientation), `overlayRgba` (premultiplied RGBA bytes),
  /// `overlayWidth`, `overlayHeight`, `overlayLeft`, `overlayTop` (output pixels), `quality` (1..100),
  /// `exif` (null = only Orientation=1, no GPS): `lat`, `lon`, `altitude`, `accuracyMeters`, `capturedLocal`
  /// ("yyyy:MM:dd HH:mm:ss" wall clock), `utcOffset` ("+05:30"), `gpsUtcMillis` (epoch ms -> GPSDateStamp /
  /// GPSTimeStamp in UTC), `make`, `model`, `software`, `userComment`. Test-only extras: `debugFailAttempts`
  /// (the first N attempts fail as out-of-memory), `stripeMB` (Android stripe budget, default 24).
  ///
  /// Returns `width`, `height`, `decodeMode`, `inSampleSize`, `decodeMs`, `drawMs`, `encodeMs`, `exifMs`,
  /// `totalMs`, `downscaledForMemory`. Errors: [PlatformException] with code `NOT_FOUND`, `OOM` or `COMPOSITE`.
  static Future<Map<String, Object?>> composite(Map<String, Object?> args) async =>
      Map<String, Object?>.from((await channel.invokeMethod<Map<Object?, Object?>>('composite', args))!);

  /// Plays the system camera shutter click (Android `MediaActionSound`; a no-op on iOS, where the camera plays it).
  static Future<void> shutterSound() => channel.invokeMethod<void>('shutterSound');

  /// A square map around `lat` / `lon` with a pin at the centre, as PNG bytes. iOS: MapKit (MKMapSnapshotter), keeps
  /// the "Apple Maps" logo it is drawn with (MKMapSnapshotter draws no "Legal" link). Android: Google Maps SDK lite mode + `GoogleMap.snapshot()`, keeps the
  /// Google logo; needs the manifest key (see [mapSnapshotAvailable]). Arguments: `lat`, `lon`, `size` (side in
  /// points, default 160), `scale` (default 3), `spanMeters` (default 500), `dark`. Errors: [PlatformException]
  /// `COMPOSITE` (offline, refused, 10 s timeout on Android) or `UNAVAILABLE` (Android without a key).
  static Future<Uint8List?> mapSnapshot(Map<String, Object?> args) => channel.invokeMethod<Uint8List>('mapSnapshot', args);

  /// Whether this platform has a [mapSnapshot] code path (iOS MapKit, Android Google Maps lite mode). On Android it
  /// can still be unavailable at runtime: ask [mapSnapshotAvailable].
  static bool get hasMapSnapshot =>
      !kIsWeb && (defaultTargetPlatform == TargetPlatform.iOS || defaultTargetPlatform == TargetPlatform.android);

  /// Whether [mapSnapshot] can draw a map here: iOS always (MapKit needs no key); Android only when the app's
  /// manifest carries a non-empty `com.google.android.geo.API_KEY`. Never throws (false on any error).
  static Future<bool> mapSnapshotAvailable() async {
    if (kIsWeb) return false;
    if (defaultTargetPlatform == TargetPlatform.iOS) return true;
    if (defaultTargetPlatform != TargetPlatform.android) return false;
    try {
      return await channel.invokeMethod<bool>('mapAvailable') ?? false;
    } catch (_) {
      return false;
    }
  }

  /// `width` / `height` after EXIF orientation, plus `orientation`, `storedWidth`, `storedHeight`.
  static Future<Map<String, Object?>> orientedSize(String path) async =>
      Map<String, Object?>.from((await channel.invokeMethod<Map<Object?, Object?>>('orientedSize', {'path': path}))!);
}
