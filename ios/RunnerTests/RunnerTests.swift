import Flutter
import UIKit
import XCTest
@testable import Runner

class RunnerTests: XCTestCase {
  func testQuickReadinessAcceptsExpectedShape() {
    let report = GeneratedTextQuality.inspect(
      rawText: "OK Gemma ready.",
      taskType: "quick_readiness",
      userPrompt: "Run a short readiness check."
    )

    XCTAssertEqual(report.status, "accepted")
    XCTAssertTrue(report.rejectionSignals.isEmpty)
    XCTAssertEqual(report.lengthBucket, "tiny")
  }

  func testChatRejectsPromptEchoAndControlTokens() {
    let report = GeneratedTextQuality.inspect(
      rawText: "<start_of_turn>model\nGrounded context JSON: {\"risk\": 42}",
      taskType: "chat",
      userPrompt: "Why is my risk higher today?"
    )

    XCTAssertEqual(report.status, "rejected")
    XCTAssertTrue(report.rejectionSignals.contains("control_token_output"))
    XCTAssertTrue(report.rejectionSignals.contains("prompt_echo"))
    XCTAssertEqual(report.cleanedText, "model Grounded context JSON: {\"risk\": 42}")
  }
}
