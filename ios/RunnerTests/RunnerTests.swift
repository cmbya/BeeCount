import Flutter
import UIKit
import XCTest
@testable import Runner

class RunnerTests: XCTestCase {
  @available(iOS 16.0, *)
  @MainActor
  func testConfirmedBridgeMatchesConcurrentReplies() async throws {
    let bridge = AppIntentsBridge()
    var events: [[String: Any]] = []
    _ = bridge.onListen(withArguments: nil) { value in
      guard let text = value as? String,
            let data = text.data(using: .utf8),
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            object["operation"] as? String == "native-test" else { return }
      events.append(object)
      if events.count == 2 {
        for event in events.reversed() {
          bridge.handle(FlutterMethodCall(methodName: "shortcutReply", arguments: [
            "callId": event["callId"]!, "response": event["marker"]!
          ])) { _ in }
        }
      }
    }
    defer { _ = bridge.onCancel(withArguments: nil) }
    async let first = AppIntentsBridge.request(["operation": "native-test", "marker": "first"], timeout: 2)
    async let second = AppIntentsBridge.request(["operation": "native-test", "marker": "second"], timeout: 2)
    let result = try await (first, second)
    XCTAssertEqual(result.0, "first")
    XCTAssertEqual(result.1, "second")
  }

  @available(iOS 16.0, *)
  @MainActor
  func testConfirmedBridgeTimeoutAndLateReply() async throws {
    let bridge = AppIntentsBridge()
    var callId: String?
    _ = bridge.onListen(withArguments: nil) { value in
      if let text = value as? String, let data = text.data(using: .utf8),
         let event = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
         event["operation"] as? String == "timeout-test" { callId = event["callId"] as? String }
    }
    defer { _ = bridge.onCancel(withArguments: nil) }
    let response = try await AppIntentsBridge.request(["operation": "timeout-test"], timeout: 0.05)
    XCTAssertTrue(response.contains("RESULT_UNKNOWN"))
    let id = try XCTUnwrap(callId)
    for _ in 0..<2 {
      bridge.handle(FlutterMethodCall(methodName: "shortcutReply", arguments: ["callId": id, "response": "late"])) { _ in }
    }
  }
  @available(iOS 16.0, *)
  @MainActor
  func testConfirmedMoneyAndNoteSemantics() throws {
    XCTAssertEqual(try ConfirmedBilling.minor("12.30"), 1230)
    XCTAssertEqual(try ConfirmedBilling.minor("123", digits: 0), 123)
    XCTAssertEqual(try ConfirmedBilling.minor("1.234", digits: 3), 1234)
    XCTAssertThrowsError(try ConfirmedBilling.minor("0"))
    XCTAssertThrowsError(try ConfirmedBilling.minor("-1"))
    XCTAssertThrowsError(try ConfirmedBilling.minor("1.001"))
    XCTAssertEqual(ConfirmedBilling.money(1234, digits: 3), "1.234")
    XCTAssertEqual(ConfirmedBilling.money(30000), "300.00")
    XCTAssertEqual(ConfirmedBilling.updatedNote("原文", action: "追加", value: "新文"), "原文新文")
    XCTAssertEqual(ConfirmedBilling.updatedNote("原文", action: "清空重填", value: "替换"), "替换")
    XCTAssertEqual(ConfirmedBilling.updatedNote("原文", action: "保存空备注", value: nil), "")
    XCTAssertEqual(ConfirmedBilling.updatedNote("原文", action: "编辑", value: nil), "原文")
    XCTAssertEqual(ConfirmedBilling.updatedNote("原文", action: "取消修改", value: "丢弃"), "原文")
  }

  private func screenshot(width: CGFloat, height: CGFloat) throws -> Data {
    let format = UIGraphicsImageRendererFormat()
    format.scale = 1
    let size = CGSize(width: width, height: height)
    let image = UIGraphicsImageRenderer(size: size, format: format).image { context in
      UIColor.red.setFill()
      context.fill(CGRect(origin: .zero, size: size))
    }
    return try XCTUnwrap(image.pngData())
  }

  func testShortcutPreservesOriginalBytesAndBoundsRecognitionCopy() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }

    let source = try screenshot(width: 100, height: 5000)
    let images = try ShortcutBillingImages.prepare(source, keepOriginal: true, directory: directory)
    XCTAssertEqual(try Data(contentsOf: images.attachment), source)
    XCTAssertEqual(images.attachment.pathExtension, "png")
    XCTAssertNotEqual(images.attachment, images.recognition)
    let original = try XCTUnwrap(UIImage(contentsOfFile: images.attachment.path))
    XCTAssertEqual(original.size, CGSize(width: 100, height: 5000))
    let recognition = try XCTUnwrap(UIImage(contentsOfFile: images.recognition.path))
    XCTAssertLessThanOrEqual(recognition.size.width, 1920)
    XCTAssertLessThanOrEqual(recognition.size.height, 1920)
  }

  func testShortcutDefaultRetainsJPEGAttachmentAndSmallImagesAreNotEnlarged() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }

    let source = try screenshot(width: 500, height: 600)
    let images = try ShortcutBillingImages.prepare(source, keepOriginal: false, directory: directory)
    XCTAssertEqual(images.attachment.pathExtension, "jpg")
    XCTAssertNotEqual(try Data(contentsOf: images.attachment), source)
    let attachment = try XCTUnwrap(UIImage(contentsOfFile: images.attachment.path))
    XCTAssertEqual(attachment.size, CGSize(width: 500, height: 600))
    let recognition = try XCTUnwrap(UIImage(contentsOfFile: images.recognition.path))
    XCTAssertEqual(recognition.size, CGSize(width: 500, height: 600))
  }
}
