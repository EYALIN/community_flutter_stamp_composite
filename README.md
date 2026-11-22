# community_flutter_stamp_composite

Native JPEG composite for GPS-stamp photos (Android Kotlin, iOS Swift; MethodChannel
`community_flutter_stamp_composite`) for GPS / timestamp camera apps: decode, rotate, crop, overlay a stamp and
write EXIF + GPS in one native pass, without the full-resolution bitmap ever existing. The calls are map-based, so
an app can wrap them in its own typed request / result objects. Optional map snapshot for a mini-map in the stamp.

<!-- support:top:start -->
## ❤️ Support this plugin

I build and maintain this plugin, and [a whole family of free Flutter plugins](https://github.com/EYALIN?tab=repositories&q=community_flutter), in my free time. Every Android and iOS release changes something underneath them (new SDK levels, Swift Package Manager, privacy manifests, OEM quirks), and keeping them working takes hours every month.

**If this plugin saved you from writing the platform code yourself, or it ships in an app that earns money, please sponsor its development.** Even $5 a month makes a real difference. It decides how fast issues get fixed, how quickly the plugin supports each new Android and iOS release, and which features come next. Issues and feature requests from sponsors are looked at first.

[![Sponsor Me](https://img.shields.io/static/v1?label=Sponsor%20Me&style=for-the-badge&message=%E2%9D%A4&logo=GitHub&color=%23fe8e86)](https://github.com/sponsors/EYALIN)

Not able to sponsor? A ⭐ on [GitHub](https://github.com/EYALIN) and a 👍 on pub.dev help other developers find it. Thank you!
<!-- support:top:end -->

| | Android | iOS |
|---|---|---|
| Minimum | API 24 | iOS 15 |
| `composite`, `orientedSize` | yes | yes |
| `mapSnapshot` | Google Maps SDK lite mode (the app's Maps API key) | MapKit `MKMapSnapshotter` |
| `shutterSound` | `MediaActionSound` | no-op (the camera plays it) |

## Install

```sh
flutter pub add community_flutter_stamp_composite
```

## What `composite` does

1. Decodes the camera JPEG **straight to the output size** — the full 48 MP bitmap never exists:
   - Android: `exact-sample` (BitmapFactory `inSampleSize` = 2^k, libjpeg scaled IDCT) when the output is the
     whole source / 2^k; otherwise `stripes` — `BitmapRegionDecoder` decodes horizontal stripes of only the
     stored region the output keeps, each drawn transformed into the output bitmap.
   - iOS: `CGImageSourceCreateThumbnailAtIndex` at the cover size with the EXIF transform applied.
2. Transform = **EXIF orientation -> cover centre-crop -> `extraRotation` (clockwise) -> mirror -> scale**.
   A different output ratio (16:9 on a 4:3 sensor) is covered and centre-cropped, never stretched.
3. Draws the stamp overlay (premultiplied RGBA from `dart:ui` `ImageByteFormat.rawRgba`) at
   (`overlayLeft`, `overlayTop`) in output pixels.
4. Encodes JPEG and writes EXIF: Orientation = 1, DateTimeOriginal / DateTime / DateTimeDigitized, OffsetTime*,
   GPS latitude / longitude / altitude / HPositioningError / DateStamp / TimeStamp (UTC), Make, Model, Software,
   UserComment. With `exif == null` only Orientation = 1 is written and no GPS can leak from the source.

Everything runs on one background worker (Android single-thread executor, iOS serial queue + autoreleasepool);
the platform thread only enqueues and replies.

The caller passes the exact output size (`outWidth` / `outHeight`, from `StampGeometry.outputSize`) and renders the overlay at that size first; native never derives its own size, except on
the out-of-memory retry (half the size, overlay scaled with it, `downscaledForMemory: true`). A second memory
failure returns `OOM`. Errors: `NOT_FOUND`, `OOM`, `COMPOSITE`.

GPS precision: Android writes seconds at 1e-7". iOS ImageIO writes 0.01" (up to ~2.8e-6°), so the plugin rewrites
the two latitude / longitude rationals in place after encoding (same bytes, no re-encode) at 1e-7".

## API

```dart
final o = await CommunityFlutterStampComposite.orientedSize(path); // width/height upright, orientation, stored size
final size = StampGeometry.outputSize(srcOrientedW: o['width'], srcOrientedH: o['height'], maxLongEdge: 4000, extraRotation: 0);
final r = await CommunityFlutterStampComposite.composite({'src': path, 'out': out, 'outWidth': size.width, 'outHeight': size.height, ...});
```

The map keys are listed in the dartdoc on `composite`. See [example/lib/main.dart](example/lib/main.dart) for a
complete app.

## Tests

- `flutter test` — `StampGeometry` (8 EXIF orientations x 4 rotations x mirror, cover crop, size rule).
- `example/android`: `./gradlew :community_flutter_stamp_composite:testDebugUnitTest` — the same matrix in Kotlin.
- `tool/test_swift_transform.sh` — the same matrix in Swift + the GPS patch, host-side.
- `example/integration_test/composite_test.dart` — on a device / emulator / simulator.

## License

MIT — see [LICENSE](LICENSE). Issues and pull requests are welcome at
[github.com/EYALIN/community_flutter_stamp_composite](https://github.com/EYALIN/community_flutter_stamp_composite/issues).

<!-- support:bottom:start -->
## Support

If this plugin is useful to you, please [sponsor its development](https://github.com/sponsors/EYALIN). It keeps the plugin maintained for every new Android and iOS release.
<!-- support:bottom:end -->
