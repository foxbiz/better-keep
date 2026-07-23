import Flutter
import UIKit
import XCTest
@testable import Runner

class RunnerTests: XCTestCase {
  func testAssistantBridgeParsesSavedResult() {
    let result = AssistantNoteBridgeResult.fromFlutter([
      "status": "saved",
      "noteId": 42,
    ])

    XCTAssertEqual(result.status, .saved)
    XCTAssertEqual(result.noteId, 42)
  }

  func testAssistantBridgeRejectsMalformedResult() {
    XCTAssertEqual(AssistantNoteBridgeResult.fromFlutter(nil).status, .failed)
    XCTAssertEqual(
      AssistantNoteBridgeResult.fromFlutter(["status": "unknown"]).status,
      .failed
    )
  }
}
