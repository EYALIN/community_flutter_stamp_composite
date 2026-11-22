import MapKit
import UIKit

/// The stamp's mini-map: one MKMapSnapshotter image of a square region around a position, with a pin at the centre,
/// encoded as PNG. MapKit needs no API key; the coordinates go to Apple's map service.
///
/// The snapshot keeps MapKit's own "Apple Maps" logo exactly as the snapshotter draws it (the Apple Developer Program
/// License Agreement, Attachment 6 section 2.1: no removing, obscuring or altering Apple's or its licensors' logos
/// and legal notices). MKMapSnapshotter draws no "Legal" link (that is an interactive MKMapView control), so there is
/// none in the image to keep. Only the pin is drawn on top, at the centre, clear of the logo.
enum MapSnapshot {
  /// Arguments: `lat`, `lon` (required), `size` (square side in points, default 160), `scale` (default 3),
  /// `spanMeters` (default 500), `dark` (default false). Completes with PNG bytes, or a StampError.
  static func run(_ args: [String: Any], completion: @escaping (Result<Data, StampError>) -> Void) {
    guard let lat = (args["lat"] as? NSNumber)?.doubleValue, let lon = (args["lon"] as? NSNumber)?.doubleValue,
          CLLocationCoordinate2DIsValid(CLLocationCoordinate2D(latitude: lat, longitude: lon)) else {
      completion(.failure(.composite("lat and lon are required"))); return
    }
    let side = max(32, min(512, (args["size"] as? NSNumber)?.doubleValue ?? 160))
    let scale = max(1, min(4, (args["scale"] as? NSNumber)?.doubleValue ?? 3))
    let span = max(50, min(50_000, (args["spanMeters"] as? NSNumber)?.doubleValue ?? 500))
    let dark = args["dark"] as? Bool ?? false
    let centre = CLLocationCoordinate2D(latitude: lat, longitude: lon)

    let options = MKMapSnapshotter.Options()
    options.region = MKCoordinateRegion(center: centre, latitudinalMeters: span, longitudinalMeters: span)
    options.size = CGSize(width: side, height: side)
    options.mapType = .standard
    options.showsBuildings = true
    options.traitCollection = UITraitCollection(traitsFrom: [
      UITraitCollection(displayScale: scale),
      UITraitCollection(userInterfaceStyle: dark ? .dark : .light),
    ])

    let snapshotter = MKMapSnapshotter(options: options)
    // MapKit's snapshotter is started from the main queue; the drawing runs on the composite queue.
    DispatchQueue.main.async {
      snapshotter.start(with: CommunityFlutterStampCompositePlugin.queue) { snapshot, error in
        guard let snapshot = snapshot else {
          completion(.failure(.composite("snapshot failed: \(error.map { "\($0)" } ?? "no image")"))); return
        }
        let data: Data? = autoreleasepool {
          let format = UIGraphicsImageRendererFormat()
          format.scale = snapshot.image.scale
          format.opaque = true
          let renderer = UIGraphicsImageRenderer(size: snapshot.image.size, format: format)
          let image = renderer.image { ctx in
            snapshot.image.draw(at: .zero)
            drawPin(ctx.cgContext, at: snapshot.point(for: centre), side: side)
          }
          return image.pngData()
        }
        guard let png = data else { completion(.failure(.composite("png encode failed"))); return }
        completion(.success(png))
      }
    }
  }

  /// A blue dot with a white ring and a soft shadow (#0743EE), sized to the map.
  static func drawPin(_ c: CGContext, at p: CGPoint, side: Double) {
    let r = CGFloat(max(5, side * 0.045))
    c.saveGState()
    c.setShadow(offset: CGSize(width: 0, height: r * 0.15), blur: r * 0.6, color: UIColor.black.withAlphaComponent(0.35).cgColor)
    c.setFillColor(UIColor.white.cgColor)
    c.fillEllipse(in: CGRect(x: p.x - r, y: p.y - r, width: 2 * r, height: 2 * r))
    c.restoreGState()
    let inner = r * 0.68
    c.setFillColor(UIColor(red: 0x07 / 255.0, green: 0x43 / 255.0, blue: 0xEE / 255.0, alpha: 1).cgColor)
    c.fillEllipse(in: CGRect(x: p.x - inner, y: p.y - inner, width: 2 * inner, height: 2 * inner))
  }
}
