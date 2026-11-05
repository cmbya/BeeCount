import Flutter
import UIKit
import XCTest
@testable import Runner

class RunnerTests: XCTestCase {
  @available(iOS 16.0, *)
  @MainActor
  func testRecognitionParametersOverrideConfigurationWithoutLosingDefaults() throws {
    var intent = RecognizeConfirmBillingIntent()
    intent.configuration = try ConfirmedBilling.encode(["tagIds": [3], "excludeFromBudget": true, "ledgerId": 1])
    let inherited = try intent.recognitionConfiguration()
    XCTAssertEqual(inherited["tagIds"] as? [Int], [3])
    XCTAssertEqual(inherited["excludeFromBudget"] as? Bool, true)
    intent.tags = [BillingTag(id: 4, name: "家庭"), BillingTag(id: 4, name: "家庭")]
    intent.excluded = false
    let overridden = try intent.recognitionConfiguration()
    XCTAssertEqual(overridden["tagIds"] as? [Int], [4])
    XCTAssertEqual(overridden["excludeFromBudget"] as? Bool, false)
    XCTAssertEqual(overridden["ledgerId"] as? Int, 1)
    intent.clearTags = true
    XCTAssertEqual(try intent.recognitionConfiguration()["tagIds"] as? [Int], [])
  }

  @available(iOS 16.0, *)
  @MainActor
  func testRecognitionTimeoutNeverClaimsAnUnknownCommit() async throws {
    let response = try await AppIntentsBridge.request(["operation": "recognize"], timeout: 0.01)
    let object = try ConfirmedBilling.decode(response)
    XCTAssertEqual(object["code"] as? String, "RECOGNITION_TIMEOUT")
    XCTAssertTrue((object["message"] as? String ?? "").contains("未入账"))
  }

  private func menuValue(_ action: String, _ values: [String]) -> String {
    values.first { $0 == action || $0.hasPrefix(action + "：") } ?? action
  }

  @available(iOS 16.0, *)
  @MainActor
  private func editorOptions(_ type: String = "expense", ledger: Int = 1) -> [String: Any] {
    ["ledgerId": ledger, "currency": "CNY", "minorDigits": 2,
     "ledgers": [["id": 1, "name": "个人"], ["id": 2, "name": "家庭"]],
     "accounts": [["id": 1, "name": "支付宝"], ["id": 2, "name": "银行卡"]],
     "categories": type == "transfer" ? [] : [["id": type == "income" ? 20 : 10, "name": type == "income" ? "工资" : "餐饮"]],
     "tags": [["id": 3, "name": "个人"], ["id": 4, "name": "家庭"]], "defaults": ["accountId": 1]]
  }

  @available(iOS 16.0, *)
  @MainActor
  private func editorDraft(_ type: String = "expense") throws -> String {
    try ConfirmedBilling.encode(["status": "draft", "ledgerId": 1, "currency": "CNY", "requestId": UUID().uuidString,
      "candidates": [["type": type, "accountId": 1, "amountMinor": 30000, "categoryId": 10, "note": "原文", "tagIds": [3], "excludeFromBudget": false]]])
  }

  @available(iOS 16.0, *)
  @MainActor
  func testConfirmationMenuShowsEditableValuesAndSavesFinalValues() async throws {
    var choices = ["金额", "分类", "1. 餐饮", "账户", "2. 银行卡", "时间", "备注", "追加", "标签", "清空所有标签", "○ 家庭 [4]", "完成标签选择", "不计预算", "不计入预算", "确认提交"]
    var inputs = ["127.89", "2026-11-05T12:32:00+08:00", "生活缴费"]
    var sawValues = false
    let editor = ConfirmedBillingEditor(draft: try editorDraft(), choose: { values, prompt in
      if prompt == "确认支出信息" {
        XCTAssertTrue(values.contains { $0.hasPrefix("金额：") })
        XCTAssertTrue(values.contains { $0.hasPrefix("分类：") })
        XCTAssertTrue(values.contains { $0.hasPrefix("账户：") })
        XCTAssertTrue(values.contains("取消提交"))
        if values.contains("金额：127.89") && values.contains("备注：原文生活缴费") && values.contains("标签：家庭") { sawValues = true }
      }
      let selected = self.menuValue(choices.removeFirst(), values)
      XCTAssertTrue(values.contains(selected), selected)
      return selected
    }, input: { _ in inputs.removeFirst() }, call: { request in
      request["operation"] as? String == "validate" ? ["status": "valid"] : self.editorOptions()
    })
    let result = try ConfirmedBilling.decode(await editor.runEditor())
    XCTAssertTrue(sawValues)
    XCTAssertEqual(result["accountId"] as? Int, 2)
    XCTAssertEqual(result["occurredAt"] as? String, "2026-11-05T12:32:00+08:00")
    let entry = try XCTUnwrap((result["entries"] as? [[String: Any]])?.first)
    XCTAssertEqual(entry["amountMinor"] as? Int, 12789)
    XCTAssertEqual(entry["excludeFromBudget"] as? Bool, true)
    XCTAssertEqual(entry["tagIds"] as? [Int], [4])
    XCTAssertTrue(choices.isEmpty)
  }

  @available(iOS 17.0, *)
  func testOnlyUserFacingBillingActionsAreDiscoverable() {
    XCTAssertFalse(BillingOptionsIntent.isDiscoverable)
    XCTAssertFalse(ImageBillingDraftIntent.isDiscoverable)
    XCTAssertFalse(TextBillingDraftIntent.isDiscoverable)
    XCTAssertFalse(EditBillingDraftIntent.isDiscoverable)
    XCTAssertFalse(CommitConfirmedBillingIntent.isDiscoverable)
    XCTAssertFalse(CustomExpenseBillingIntent.isDiscoverable)
    XCTAssertFalse(CustomIncomeBillingIntent.isDiscoverable)
    XCTAssertFalse(CustomTransferBillingIntent.isDiscoverable)
    XCTAssertFalse(RecognizeConfirmBillingIntent.isDiscoverable)
    XCTAssertTrue(ImageConfirmBillingIntent.isDiscoverable)
    XCTAssertTrue(TextConfirmBillingIntent.isDiscoverable)
  }

  @available(iOS 16.0, *)
  @MainActor
  func testEditorRejectsOversizeSplitAndRecomputesAfterDelete() async throws {
    var choices = ["拆分或新增明细", "开始拆分", "金额", "分类", "1. 餐饮", "完成此笔", "返回修改", "金额", "完成此笔",
      "删除明细", "第 1 笔 80.00", "拆分或新增明细", "分类", "1. 餐饮", "完成此笔", "确认提交"]
    var inputs = ["400", "80"]
    var rejected = false
    let editor = ConfirmedBillingEditor(draft: try editorDraft(), choose: { values, prompt in
      if prompt.contains("超过剩余金额") { rejected = true }
      let selected = self.menuValue(choices.removeFirst(), values); XCTAssertTrue(values.contains(selected), selected); return selected
    }, input: { _ in inputs.removeFirst() }, call: { request in
      request["operation"] as? String == "validate" ? ["status": "valid"] : self.editorOptions()
    })
    let result = try ConfirmedBilling.decode(await editor.runEditor())
    let entries = try XCTUnwrap(result["entries"] as? [[String: Any]])
    XCTAssertTrue(rejected)
    XCTAssertEqual(entries.count, 1)
    XCTAssertEqual(entries[0]["amountMinor"] as? Int, 30000)
    XCTAssertTrue(choices.isEmpty)
  }

  @available(iOS 16.0, *)
  @MainActor
  func testEditorIncomeSelectsIncomeCategoryWithoutBudgetMenu() async throws {
    var choices = ["收支类型", "收入", "分类", "1. 工资", "确认提交"]
    var incomeFields = false
    let editor = ConfirmedBillingEditor(draft: try editorDraft(), choose: { values, _ in
      if values.contains("确认提交") && values.contains(where: { $0 == "分类：待选择" }) { incomeFields = true; XCTAssertFalse(values.contains { $0.hasPrefix("不计预算") }) }
      let selected = self.menuValue(choices.removeFirst(), values); XCTAssertTrue(values.contains(selected), selected); return selected
    }, input: { _ in "" }, call: { request in
      request["operation"] as? String == "validate" ? ["status": "valid"] : self.editorOptions(request["type"] as? String ?? "expense")
    })
    let result = try ConfirmedBilling.decode(await editor.runEditor())
    XCTAssertTrue(incomeFields)
    XCTAssertEqual(result["type"] as? String, "income")
    XCTAssertEqual((result["entries"] as? [[String: Any]])?.first?["categoryId"] as? Int, 20)
    XCTAssertTrue(choices.isEmpty)
  }

  @available(iOS 16.0, *)
  @MainActor
  func testEditorSplitsAndSummarizesWithoutSaving() async throws {
    var choices = ["拆分或新增明细", "开始拆分", "金额", "分类", "1. 餐饮", "完成此笔",
      "拆分或新增明细", "金额", "分类", "1. 餐饮", "预算标记", "不计入预算", "完成此笔",
      "拆分或新增明细", "分类", "1. 餐饮", "完成此笔", "确认提交"]
    var inputs = ["80", "150"]
    var prompts: [String] = []
    var validated = 0
    let editor = ConfirmedBillingEditor(draft: try editorDraft(), choose: { values, prompt in
      prompts.append(prompt)
      let selected = self.menuValue(choices.removeFirst(), values)
      XCTAssertTrue(values.contains(selected), selected)
      return selected
    }, input: { _ in inputs.removeFirst() }, call: { request in
      if request["operation"] as? String == "validate" { validated += 1; return ["status": "valid"] }
      XCTAssertEqual(request["operation"] as? String, "options")
      return self.editorOptions()
    })
    let result = try ConfirmedBilling.decode(await editor.runEditor())
    let entries = try XCTUnwrap(result["entries"] as? [[String: Any]])
    XCTAssertEqual(entries.compactMap { $0["amountMinor"] as? Int }, [8000,15000,7000])
    XCTAssertEqual(entries[1]["excludeFromBudget"] as? Bool, true)
    XCTAssertTrue(prompts.contains { $0.contains("剩余：220.00") })
    XCTAssertTrue(prompts.contains { $0.contains("剩余：70.00") })
    XCTAssertEqual(validated, 1)
    XCTAssertTrue(choices.isEmpty)
  }

  @available(iOS 16.0, *)
  @MainActor
  func testEditorNoteCancellationPreservesThenClearsFinalValue() async throws {
    var choices = ["备注", "编辑", "备注", "追加", "备注", "保存空备注", "确认提交"]
    var inputCount = 0
    var seenOriginalAfterCancel = false
    let editor = ConfirmedBillingEditor(draft: try editorDraft(), choose: { values, prompt in
      if inputCount == 1 && prompt.contains("原备注：原文") { seenOriginalAfterCancel = true }
      let selected = self.menuValue(choices.removeFirst(), values); XCTAssertTrue(values.contains(selected)); return selected
    }, input: { _ in
      inputCount += 1
      if inputCount == 1 { throw CancellationError() }
      return "追加"
    }, call: { request in request["operation"] as? String == "validate" ? ["status":"valid"] : self.editorOptions() })
    let result = try ConfirmedBilling.decode(await editor.runEditor())
    XCTAssertEqual((result["entries"] as? [[String: Any]])?.first?["note"] as? String, "")
    XCTAssertTrue(seenOriginalAfterCancel)
  }

  @available(iOS 16.0, *)
  @MainActor
  func testEditorLedgerAndTransferSelection() async throws {
    var choices = ["账本", "2. 家庭", "收支类型", "转账", "1. 银行卡", "确认提交"]
    let editor = ConfirmedBillingEditor(draft: try editorDraft(), choose: { values, _ in
      let selected = self.menuValue(choices.removeFirst(), values); XCTAssertTrue(values.contains(selected)); return selected
    }, input: { _ in XCTFail("Unexpected input"); return "" }, call: { request in
      if request["operation"] as? String == "validate" { return ["status":"valid"] }
      return self.editorOptions(request["type"] as? String ?? "expense", ledger: request["ledgerId"] as? Int ?? 1)
    })
    let result = try ConfirmedBilling.decode(await editor.runEditor())
    XCTAssertEqual(result["ledgerId"] as? Int, 2)
    XCTAssertEqual(result["type"] as? String, "transfer")
    XCTAssertEqual(result["accountId"] as? Int, 1)
    XCTAssertEqual(result["toAccountId"] as? Int, 2)
  }

  @available(iOS 16.0, *)
  @MainActor
  func testEditorCancelNeverValidatesOrCommits() async throws {
    var writes = 0
    let editor = ConfirmedBillingEditor(draft: try editorDraft(), choose: { _, _ in "取消提交" }, input: { _ in "" }, call: { request in
      if request["operation"] as? String != "options" { writes += 1 }
      return self.editorOptions()
    })
    do { _ = try await editor.runEditor(); XCTFail("Must cancel") } catch {}
    XCTAssertEqual(writes, 0)
  }
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


  @available(iOS 16.0, *)
  @MainActor
  func testRecognitionPresetSupportsLedgerAndExplicitEmptyTags() {
    let ledger = BillingLedger(id: 2, name: "家庭")
    let config = RecognitionBillingFlow.configuration(ledger: ledger, tags: [BillingTag(id: 3, name: "个人")], clearTags: true, excluded: false)
    XCTAssertEqual(config["ledgerId"] as? Int, 2)
    XCTAssertEqual(config["tagIds"] as? [Int], [])
    XCTAssertEqual(config["excludeFromBudget"] as? Bool, false)
    XCTAssertNil(config["accountId"])
  }

  @available(iOS 16.0, *)
  @MainActor
  func testMissingRecognizedAccountPromptsInsteadOfUsingDefault() async throws {
    var draft = try ConfirmedBilling.decode(editorDraft())
    var candidates = try XCTUnwrap(draft["candidates"] as? [[String: Any]])
    candidates[0].removeValue(forKey: "accountId")
    candidates[0]["requiresAccountSelection"] = true
    draft["candidates"] = candidates
    var choices = ["2. 银行卡", "确认提交"]
    var asked = false
    let editor = ConfirmedBillingEditor(draft: try ConfirmedBilling.encode(draft), choose: { values, prompt in
      if prompt.contains("选择付款") { asked = true }
      let selected = self.menuValue(choices.removeFirst(), values)
      XCTAssertTrue(values.contains(selected))
      return selected
    }, input: { _ in XCTFail("Unexpected input"); return "" }, call: { request in
      request["operation"] as? String == "validate" ? ["status": "valid"] : self.editorOptions()
    })
    let result = try ConfirmedBilling.decode(await editor.runEditor())
    XCTAssertTrue(asked)
    XCTAssertEqual(result["accountId"] as? Int, 2)
    XCTAssertTrue(choices.isEmpty)
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
