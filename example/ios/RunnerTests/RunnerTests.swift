import Flutter
import UIKit
import XCTest

@testable import community_flutter_stamp_composite

/// XCTest entry for the Runner scheme. The full orientation / crop matrix runs host-side
/// (tool/test_swift_transform.sh) and on a simulator via integration_test/composite_test.dart.
class RunnerTests: XCTestCase {
  func testUnknownMethodIsNotImplemented() {
    let plugin = CommunityFlutterStampCompositePlugin()
    let done = expectation(description: "result")
    plugin.handle(FlutterMethodCall(methodName: "nope", arguments: nil)) { result in
      XCTAssertTrue((result as AnyObject) === (FlutterMethodNotImplemented as AnyObject))
      done.fulfill()
    }
    waitForExpectations(timeout: 1)
  }

  func testRotation180PutsBottomRightAtTopLeft() {
    let t = StampTransform.build(exifOrientation: 1, extraRotation: 180, mirror: false, srcW: 30, srcH: 40, outW: 30, outH: 40)
    XCTAssertEqual(t.mapX(30, 40), 0)
    XCTAssertEqual(t.mapY(30, 40), 0)
  }
}
