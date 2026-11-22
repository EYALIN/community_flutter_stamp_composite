## 1.2.0

* First release on pub.dev.
* Android `mapSnapshot`: a Google Maps SDK for Android LITE-MODE map (offscreen
  `MapView`, `GoogleMapOptions().liteMode(true)`), the same centre pin as iOS, `GoogleMap.snapshot()` as PNG, the
  Google logo left visible, a 10 s timeout. The key is the app's manifest meta-data `com.google.android.geo.API_KEY`;
  `mapAvailable` / `mapSnapshotAvailable()` is false without one (the stamp stays text only).
* `hasMapSnapshot` is now true on Android too (the code path exists); whether a map can be drawn is
  `mapSnapshotAvailable()` (iOS: always; Android: a key is in the manifest).

## 1.1.0

* iOS `mapSnapshot`: a square MKMapSnapshotter map around a position with a pin at the
  centre, PNG; keeps MapKit's "Apple Maps" logo (the snapshotter draws no "Legal" link). `hasMapSnapshot` is false on
  Android (no provider).

## 1.0.0

* Initial version.
* `composite`: decode the camera JPEG straight to the output size (Android: BitmapFactory inSampleSize when the
  output is source / 2^k with no crop, otherwise striped BitmapRegionDecoder over the crop region only; iOS: ImageIO
  thumbnail at the cover size), EXIF orientation -> cover centre-crop -> extraRotation -> mirror, premultiplied RGBA
  overlay, JPEG with EXIF / GPS / TIFF (Orientation = 1), all on one background worker.
* Out-of-memory: one retry at half the output size (`downscaledForMemory`), then `OOM`.
* `orientedSize`; pure `StampGeometry` (Dart) mirroring the native transform math.
