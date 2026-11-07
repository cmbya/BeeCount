import Flutter
import UIKit
import XCTest
import AppIntents
@testable import Runner

class RunnerTests: XCTestCase {
  @available(iOS 16.0, *)
  @MainActor
  func testRecognitionParametersOverrideDefaultsWithoutLosingLedger() {
    let inherited = RecognitionBillingFlow.configuration(ledger: BillingLedger(id: 1, name: "个人"), tags: nil, clearTags: false, excluded: nil)
    XCTAssertNil(inherited["tagIds"])
    XCTAssertNil(inherited["excludeFromBudget"])
    XCTAssertEqual(inherited["ledgerId"] as? Int, 1)
    let tags = [BillingTag(id: 4, name: "家庭"), BillingTag(id: 4, name: "家庭")]
    let overridden = RecognitionBillingFlow.configuration(ledger: BillingLedger(id: 1, name: "个人"), tags: tags, clearTags: false, excluded: false)
    XCTAssertEqual(overridden["tagIds"] as? [Int], [4])
    XCTAssertEqual(overridden["excludeFromBudget"] as? Bool, false)
    XCTAssertEqual(overridden["ledgerId"] as? Int, 1)
    XCTAssertEqual(RecognitionBillingFlow.configuration(ledger: nil, tags: tags, clearTags: true, excluded: nil)["tagIds"] as? [Int], [])
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
    var choices = ["金额", "分类", "1. 餐饮", "账户", "2. 银行卡", "时间", "备注", "标签", "不计预算", "确认提交"]
    var inputs = ["127.89", "2026-11-05T12:32:00+08:00", "生活缴费"]
    var sawValues = false
    let editor = ConfirmedBillingEditor(draft: try editorDraft(), choose: { values, prompt in
      if prompt == "确认支出信息" {
        XCTAssertTrue(values.contains { $0.hasPrefix("金额：") })
        XCTAssertTrue(values.contains { $0.hasPrefix("分类：") })
        XCTAssertTrue(values.contains { $0.hasPrefix("账户：") })
        XCTAssertTrue(values.contains("取消提交"))
        if values.contains("金额：127.89") && values.contains("备注：生活缴费") && values.contains("标签：家庭") { sawValues = true }
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
  @MainActor
  func testOnlyPrepareAndConfirmVariableActionsAreDiscoverable() {
    XCTAssertTrue(PrepareVariableBillingIntent.isDiscoverable)
    XCTAssertTrue(ConfirmVariableBillingIntent.isDiscoverable)
    XCTAssertFalse(ImageConfirmBillingIntent.isDiscoverable)
    XCTAssertFalse(TextConfirmBillingIntent.isDiscoverable)
    XCTAssertFalse(BillingValueInputIntent.isDiscoverable)
    XCTAssertFalse(AutoBillingAppIntent.isDiscoverable)
    XCTAssertFalse(PrepareVariableBillingIntent.openAppWhenRun)
    XCTAssertFalse(ConfirmVariableBillingIntent.openAppWhenRun)
    XCTAssertEqual(AutoBillingShortcuts.appShortcuts.count, 2)
  }

  @available(iOS 16.0, *)
  @MainActor
  func testEditorRejectsOversizeSplitAndRecomputesAfterDelete() async throws {
    var choices = ["拆分或新增明细", "金额", "返回修改", "金额", "分类", "1. 餐饮", "完成此笔",
      "删除明细", "第 1 笔 80.00", "拆分或新增明细", "分类", "1. 餐饮", "完成此笔", "确认提交"]
    var inputs = ["400", "80"]
    var rejected = false
    let editor = ConfirmedBillingEditor(draft: try editorDraft(), choose: { values, prompt in
      if prompt.contains("不能超过可分配金额") { rejected = true }
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
      if values.contains("确认提交") && values.contains(where: { $0 == "分类：未分类" }) { incomeFields = true; XCTAssertFalse(values.contains { $0.hasPrefix("不计预算") }) }
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
    var choices = ["拆分或新增明细", "金额", "分类", "1. 餐饮", "完成此笔",
      "拆分或新增明细", "金额", "分类", "1. 餐饮", "预算标记", "完成此笔",
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
    var choices = ["备注", "备注", "确认提交"]
    var inputCount = 0
    var seenOriginalAfterCancel = false
    let editor = ConfirmedBillingEditor(draft: try editorDraft(), choose: { values, prompt in
      if inputCount == 1 && values.contains("备注：原文") { seenOriginalAfterCancel = true }
      let selected = self.menuValue(choices.removeFirst(), values); XCTAssertTrue(values.contains(selected)); return selected
    }, input: { _ in
      inputCount += 1
      if inputCount == 1 { throw CancellationError() }
      return ""
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
    XCTAssertEqual(ConfirmedBilling.updatedNote("原文", value: "替换"), "替换")
    XCTAssertEqual(ConfirmedBilling.updatedNote("原文", value: ""), "")
    XCTAssertEqual(ConfirmedBilling.updatedNote("原文", value: nil), "原文")
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


  @available(iOS 16.0, *)
  @MainActor
  func testTagCyclesOneAtATimeWithoutSubmenu() {
    let tags: [[String: Any]] = [["id": 3], ["id": 4], ["id": 5]]
    XCTAssertEqual(ConfirmedBilling.nextTag([3], tags: tags), [4])
    XCTAssertEqual(ConfirmedBilling.nextTag([4], tags: tags), [5])
    XCTAssertEqual(ConfirmedBilling.nextTag([5], tags: tags), [3])
    XCTAssertEqual(ConfirmedBilling.nextTag([], tags: tags), [3])
    XCTAssertEqual(ConfirmedBilling.nextTag([99], tags: tags), [3])
    XCTAssertEqual(ConfirmedBilling.nextTag([3, 4], tags: tags), [3])
    XCTAssertEqual(ConfirmedBilling.nextTag([3], tags: []), [])
  }

  @available(iOS 16.0, *)
  @MainActor
  func testWarningsDoNotInterruptAndBudgetTogglesDirectly() async throws {
    var draft = try ConfirmedBilling.decode(editorDraft())
    var candidates = try XCTUnwrap(draft["candidates"] as? [[String: Any]])
    candidates[0]["warnings"] = ["账单未标明时区", "没有适用分类"]
    draft["candidates"] = candidates
    var choices = ["不计预算", "不计预算", "确认提交"]
    var states: [String] = []
    let editor = ConfirmedBillingEditor(draft: try ConfirmedBilling.encode(draft), choose: { values, prompt in
      XCTAssertEqual(prompt, "确认支出信息")
      states.append(values.first { $0.hasPrefix("不计预算：") } ?? "")
      let selected = self.menuValue(choices.removeFirst(), values)
      XCTAssertTrue(values.contains(selected))
      return selected
    }, input: { _ in XCTFail("Unexpected input"); return "" }, call: { request in
      request["operation"] as? String == "validate" ? ["status": "valid"] : self.editorOptions()
    })
    let result = try ConfirmedBilling.decode(await editor.runEditor())
    XCTAssertEqual(states, ["不计预算：计入预算", "不计预算：不计入预算", "不计预算：计入预算"])
    XCTAssertEqual((result["entries"] as? [[String: Any]])?.first?["excludeFromBudget"] as? Bool, false)
  }

  @available(iOS 16.0, *)
  @MainActor
  func testRepeatedAmountAndNoteRequestsReturnToSummary() async throws {
    var choices = ["金额", "金额", "备注", "备注", "确认提交"]
    var inputs = ["301", "302", "追加", "最终备注"]
    let editor = ConfirmedBillingEditor(draft: try editorDraft(), choose: { values, _ in
      let selected = self.menuValue(choices.removeFirst(), values)
      XCTAssertTrue(values.contains(selected)); return selected
    }, input: { _ in inputs.removeFirst() }, call: { request in
      request["operation"] as? String == "validate" ? ["status": "valid"] : self.editorOptions()
    })
    let result = try ConfirmedBilling.decode(await editor.runEditor())
    XCTAssertEqual(result["originalAmountMinor"] as? Int, 30200)
    XCTAssertEqual((result["entries"] as? [[String: Any]])?.first?["note"] as? String, "最终备注")
    XCTAssertTrue(inputs.isEmpty)
    XCTAssertTrue(choices.isEmpty)
  }


  @available(iOS 16.0, *)
  @MainActor
  func testAmountInputErrorReturnsToDraftWithoutCommit() async throws {
    var choices = ["金额", "返回账单", "确认提交"]
    var validations = 0
    let editor = ConfirmedBillingEditor(draft: try editorDraft(), choose: { values, _ in
      let selected = self.menuValue(choices.removeFirst(), values)
      XCTAssertTrue(values.contains(selected)); return selected
    }, input: { _ in throw NSError(domain: "InputTest", code: 1) }, call: { request in
      if request["operation"] as? String == "validate" { validations += 1; return ["status": "valid"] }
      XCTAssertEqual(request["operation"] as? String, "options")
      return self.editorOptions()
    })
    let result = try ConfirmedBilling.decode(await editor.runEditor())
    XCTAssertEqual(result["originalAmountMinor"] as? Int, 30000)
    XCTAssertEqual(validations, 1)
    XCTAssertTrue(choices.isEmpty)
  }


  @available(iOS 16.0, *)
  @MainActor
  func testBothBillingActionsHaveIndependentOptionalAttachment() {
    XCTAssertNil(ImageConfirmBillingIntent().attachment)
    XCTAssertNil(TextConfirmBillingIntent().attachment)
  }

  @available(iOS 16.0, *)
  @MainActor
  func testShortcutAttachmentHonorsKeepOriginalSetting() throws {
    let key = "flutter.attachmentKeepOriginal"
    let old = UserDefaults.standard.object(forKey: key)
    defer {
      if let old { UserDefaults.standard.set(old, forKey: key) }
      else { UserDefaults.standard.removeObject(forKey: key) }
    }
    let bytes = try screenshot(width: 100, height: 100)
    let file = IntentFile(data: bytes, filename: "screenshot.png")
    UserDefaults.standard.set(true, forKey: key)
    let original = try ConfirmedBilling.attachmentPayload(file)
    XCTAssertEqual(original["extension"] as? String, "png")
    XCTAssertEqual(Data(base64Encoded: original["dataBase64"] as? String ?? ""), bytes)
    UserDefaults.standard.set(false, forKey: key)
    let compressed = try ConfirmedBilling.attachmentPayload(file)
    XCTAssertEqual(compressed["extension"] as? String, "jpg")
    XCTAssertNotNil(UIImage(data: try XCTUnwrap(Data(base64Encoded: compressed["dataBase64"] as? String ?? ""))))
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
  @available(iOS 16.0, *)
  @MainActor
  func testReceiptOCRPairsColumnsByGeometry() {
    let result = ConfirmedBilling.receiptText([
      ("商品", CGRect(x: 0.1, y: 0.8, width: 0.1, height: 0.03)),
      ("商户全称", CGRect(x: 0.1, y: 0.7, width: 0.15, height: 0.03)),
      ("收单机构", CGRect(x: 0.1, y: 0.6, width: 0.15, height: 0.03)),
      ("支付方式", CGRect(x: 0.1, y: 0.5, width: 0.15, height: 0.03)),
      ("生活缴费", CGRect(x: 0.3, y: 0.801, width: 0.2, height: 0.028)),
      ("广东电网有限责任公司", CGRect(x: 0.3, y: 0.7, width: 0.5, height: 0.03)),
      ("中国光大银行", CGRect(x: 0.3, y: 0.6, width: 0.3, height: 0.03)),
      ("招商银行信用卡(4276)", CGRect(x: 0.3, y: 0.5, width: 0.5, height: 0.03))
    ])
    XCTAssertEqual(result, "商品\t生活缴费\n商户全称\t广东电网有限责任公司\n收单机构\t中国光大银行\n支付方式\t招商银行信用卡(4276)")
  }

  @available(iOS 16.0, *)
  @MainActor
  func testCancellingFirstSplitPreservesOriginalAndEditedNote() async throws {
    var choices = ["备注", "拆分或新增明细", "取消本次字段修改", "确认提交"]
    var openedDetail = false
    let editor = ConfirmedBillingEditor(draft: try editorDraft(), choose: { values, prompt in
      XCTAssertFalse(values.contains("开始拆分"))
      if prompt == "编辑账单明细" { openedDetail = true; XCTAssertTrue(values.contains("备注：已修改")) }
      let selected = self.menuValue(choices.removeFirst(), values)
      XCTAssertTrue(values.contains(selected)); return selected
    }, input: { _ in "已修改" }, call: { request in
      request["operation"] as? String == "validate" ? ["status": "valid"] : self.editorOptions()
    })
    let result = try ConfirmedBilling.decode(await editor.runEditor())
    let entries = try XCTUnwrap(result["entries"] as? [[String: Any]])
    XCTAssertTrue(openedDetail)
    XCTAssertEqual(entries.count, 1)
    XCTAssertEqual(entries[0]["amountMinor"] as? Int, 30000)
    XCTAssertEqual(entries[0]["note"] as? String, "已修改")
    XCTAssertTrue(choices.isEmpty)
  }

  @available(iOS 16.0, *)
  @MainActor
  func testDirectNoteReplacementAcrossAllTransactionTypes() async throws {
    for type in ["expense", "income", "transfer"] {
      var source = try ConfirmedBilling.decode(editorDraft(type))
      var candidates = try XCTUnwrap(source["candidates"] as? [[String: Any]])
      if type == "transfer" { candidates[0]["toAccountId"] = 2 }
      source["candidates"] = candidates
      var choices = ["备注", "确认提交"]
      var inputCount = 0
      let editor = ConfirmedBillingEditor(draft: try ConfirmedBilling.encode(source), choose: { values, _ in
        XCTAssertFalse(values.contains("编辑"))
        XCTAssertFalse(values.contains("追加"))
        let selected = self.menuValue(choices.removeFirst(), values)
        XCTAssertTrue(values.contains(selected)); return selected
      }, input: { prompt in
        inputCount += 1
        XCTAssertTrue(prompt.contains("原备注：原文"))
        return "直接替换"
      }, call: { request in
        request["operation"] as? String == "validate" ? ["status": "valid"] : self.editorOptions(type)
      })
      let result = try ConfirmedBilling.decode(await editor.runEditor())
      XCTAssertEqual((result["entries"] as? [[String: Any]])?.first?["note"] as? String, "直接替换")
      XCTAssertEqual(inputCount, 1)
      XCTAssertTrue(choices.isEmpty)
    }
  }

  // These tests use supplied menu/input responses, not the Shortcuts keyboard UI.
  @available(iOS 16.0, *)
  @MainActor
  func testStepInputSuspendsAndReplaysWithoutRepeatingMenus() async throws {
    var choices = ["备注", "金额", "确认提交"]
    var validated = 0
    let draft = try editorDraft()
    let choose: ([String], String) async throws -> String = { values, _ in
      let action = choices.removeFirst()
      let selected = self.menuValue(action, values)
      XCTAssertTrue(values.contains(selected)); return selected
    }
    let call: ([String: Any]) async throws -> [String: Any] = { request in
      if request["operation"] as? String == "validate" { validated += 1; return ["status": "valid"] }
      XCTAssertEqual(request["operation"] as? String, "options")
      return self.editorOptions()
    }
    let start = try BillingStepFlow.start(draft)
    let first = try await BillingStepFlow.advance(start, response: nil, hasResponse: false, choose: choose, call: call)
    var result = try ConfirmedBilling.decode(first)
    XCTAssertEqual(result["status"] as? String, "input")
    XCTAssertEqual((result["input"] as? [String: Any])?["currentValue"] as? String, "原文")
    XCTAssertEqual(validated, 0)
    let second = try await BillingStepFlow.advance(first, response: "改好备注", hasResponse: true, choose: choose, call: call)
    result = try ConfirmedBilling.decode(second)
    XCTAssertEqual((result["input"] as? [String: Any])?["inputType"] as? String, "number")
    XCTAssertEqual((result["input"] as? [String: Any])?["currentValue"] as? String, "300.00")
    let final = try await BillingStepFlow.advance(second, response: "127.89", hasResponse: true, choose: choose, call: call)
    result = try ConfirmedBilling.decode(final)
    XCTAssertEqual(result["status"] as? String, "confirmed")
    let submission = try ConfirmedBilling.decode(try XCTUnwrap(result["submission"] as? String))
    let entry = try XCTUnwrap((submission["entries"] as? [[String: Any]])?.first)
    XCTAssertEqual(entry["note"] as? String, "改好备注")
    XCTAssertEqual(entry["amountMinor"] as? Int, 12789)
    XCTAssertEqual(submission["requestId"] as? String, try ConfirmedBilling.decode(draft)["requestId"] as? String)
    XCTAssertEqual(validated, 1)
    XCTAssertTrue(choices.isEmpty)
  }

  @available(iOS 16.0, *)
  @MainActor
  func testStepSplitResumesInsideDetailAndRejectsOversize() async throws {
    var choices = ["拆分或新增明细", "金额", "返回修改", "金额", "备注", "完成此笔",
      "拆分或新增明细", "金额", "完成此笔", "拆分或新增明细", "完成此笔", "确认提交"]
    let answers = ["400", "80", "第一笔", "150"]
    let defaults = ["300.00", "300.00", "原文", "220.00"]
    var envelope = try BillingStepFlow.start(editorDraft())
    var response: String? = nil
    var hasResponse = false
    var inputs = 0
    for _ in 0..<10 {
      envelope = try await BillingStepFlow.advance(envelope, response: response, hasResponse: hasResponse, choose: { values, _ in
        XCTAssertFalse(values.contains("开始拆分"))
        let selected = self.menuValue(choices.removeFirst(), values)
        XCTAssertTrue(values.contains(selected)); return selected
      }, call: { request in request["operation"] as? String == "validate" ? ["status": "valid"] : self.editorOptions() })
      let result = try ConfirmedBilling.decode(envelope)
      if result["status"] as? String == "confirmed" { break }
      XCTAssertEqual(result["status"] as? String, "input")
      XCTAssertLessThan(inputs, answers.count)
      XCTAssertEqual((result["input"] as? [String: Any])?["currentValue"] as? String, defaults[inputs])
      response = answers[inputs]; inputs += 1; hasResponse = true
    }
    let result = try ConfirmedBilling.decode(envelope)
    let submission = try ConfirmedBilling.decode(try XCTUnwrap(result["submission"] as? String))
    let entries = try XCTUnwrap(submission["entries"] as? [[String: Any]])
    XCTAssertEqual(entries.compactMap { $0["amountMinor"] as? Int }, [8000, 15000, 7000])
    XCTAssertEqual(entries[0]["note"] as? String, "第一笔")
    XCTAssertEqual(inputs, 4)
    XCTAssertTrue(choices.isEmpty)
  }

  @available(iOS 16.0, *)
  @MainActor
  func testStepEmptyNoteAndCancellationNeverCommit() async throws {
    let start = try BillingStepFlow.start(editorDraft())
    let pending = try await BillingStepFlow.advance(start, response: nil, hasResponse: false, choose: { values, _ in
      self.menuValue("备注", values)
    }, call: { _ in self.editorOptions() })
    let cancelled = try await BillingStepFlow.advance(pending, response: nil, hasResponse: true, choose: { values, _ in
      XCTAssertTrue(values.contains("备注："))
      return "取消提交"
    }, call: { request in
      XCTAssertEqual(request["operation"] as? String, "options")
      return self.editorOptions()
    })
    XCTAssertEqual(try ConfirmedBilling.decode(cancelled)["status"] as? String, "cancelled")
    do {
      _ = try await BillingStepFlow.advance(pending, response: nil, hasResponse: false, choose: { _, _ in XCTFail("Must reject missing response"); return "" }, call: { _ in self.editorOptions() })
      XCTFail("Must require explicit response flag")
    } catch {}
  }

  @available(iOS 16.0, *)
  @MainActor
  func testStepExistingDetailAmountLimitAndFailedValidationReplay() async throws {
    var choices = ["拆分或新增明细", "金额", "完成此笔", "拆分或新增明细", "完成此笔",
      "编辑明细", "第 1 笔 80.00", "金额", "返回修改", "金额", "完成此笔",
      "确认提交", "返回修改", "编辑明细", "第 1 笔 80.00", "备注", "完成此笔", "确认提交"]
    let answers = ["80", "100", "80", "保持本笔"]
    var resultText = try BillingStepFlow.start(editorDraft())
    var response: String? = nil
    var hasResponse = false
    var inputIndex = 0
    var validations = 0
    for _ in 0..<10 {
      resultText = try await BillingStepFlow.advance(resultText, response: response, hasResponse: hasResponse, choose: { values, _ in
        let selected = self.menuValue(choices.removeFirst(), values)
        XCTAssertTrue(values.contains(selected)); return selected
      }, call: { request in
        if request["operation"] as? String == "validate" {
          validations += 1
          if validations == 1 { throw NSError(domain: "test", code: 1) }
          return ["status": "valid"]
        }
        return self.editorOptions()
      })
      let result = try ConfirmedBilling.decode(resultText)
      if result["status"] as? String == "confirmed" { break }
      if inputIndex == 2 { XCTAssertEqual((result["input"] as? [String: Any])?["currentValue"] as? String, "80.00") }
      response = answers[inputIndex]; inputIndex += 1; hasResponse = true
    }
    let result = try ConfirmedBilling.decode(resultText)
    let submission = try ConfirmedBilling.decode(try XCTUnwrap(result["submission"] as? String))
    let entries = try XCTUnwrap(submission["entries"] as? [[String: Any]])
    XCTAssertEqual(entries.compactMap { $0["amountMinor"] as? Int }, [8000, 22000])
    XCTAssertEqual(entries[0]["note"] as? String, "保持本笔")
    XCTAssertEqual(validations, 2)
    XCTAssertTrue(choices.isEmpty)
  }

  @available(iOS 16.0, *)
  @MainActor
  func testStepFlowRetainsManualIncomeTransferAndMissingAmount() async throws {
    for type in ["income", "transfer"] {
      var source = try ConfirmedBilling.decode(editorDraft(type))
      var candidates = try XCTUnwrap(source["candidates"] as? [[String: Any]])
      candidates[0]["note"] = "手填原样"
      if type == "transfer" { candidates[0]["toAccountId"] = 2 }
      source["candidates"] = candidates
      var choices = ["备注", "确认提交"]
      let start = try BillingStepFlow.start(ConfirmedBilling.encode(source))
      let choose: ([String], String) async throws -> String = { values, _ in
        let selected = self.menuValue(choices.removeFirst(), values)
        XCTAssertTrue(values.contains(selected)); return selected
      }
      let call: ([String: Any]) async throws -> [String: Any] = { request in
        XCTAssertNotEqual(request["operation"] as? String, "recognize")
        return request["operation"] as? String == "validate" ? ["status": "valid"] : self.editorOptions(type)
      }
      let input = try await BillingStepFlow.advance(start, response: nil, hasResponse: false, choose: choose, call: call)
      XCTAssertEqual((try ConfirmedBilling.decode(input)["input"] as? [String: Any])?["currentValue"] as? String, "手填原样")
      let final = try await BillingStepFlow.advance(input, response: "新备注", hasResponse: true, choose: choose, call: call)
      XCTAssertEqual(try ConfirmedBilling.decode(final)["status"] as? String, "confirmed")
      XCTAssertTrue(choices.isEmpty)
    }
    var source = try ConfirmedBilling.decode(editorDraft())
    var candidates = try XCTUnwrap(source["candidates"] as? [[String: Any]])
    candidates[0].removeValue(forKey: "amountMinor")
    source["candidates"] = candidates
    let missing = try await BillingStepFlow.advance(BillingStepFlow.start(ConfirmedBilling.encode(source)), response: nil, hasResponse: false,
      choose: { _, _ in XCTFail("Amount must be requested first"); return "" }, call: { _ in self.editorOptions() })
    XCTAssertEqual((try ConfirmedBilling.decode(missing)["input"] as? [String: Any])?["inputType"] as? String, "number")
  }

  @available(iOS 16.0, *)
  @MainActor
  func testStepInvalidAmountsKeepOriginalAndRequestAgain() async throws {
    for invalid in ["0", "-1", "1.001", "abc", ""] {
      var choices = ["金额", "返回修改", "金额", "确认提交"]
      let choose: ([String], String) async throws -> String = { values, _ in
        let selected = self.menuValue(choices.removeFirst(), values)
        XCTAssertTrue(values.contains(selected)); return selected
      }
      let call: ([String: Any]) async throws -> [String: Any] = { request in
        request["operation"] as? String == "validate" ? ["status": "valid"] : self.editorOptions()
      }
      let start = try BillingStepFlow.start(editorDraft())
      let first = try await BillingStepFlow.advance(start, response: nil, hasResponse: false, choose: choose, call: call)
      let retry = try await BillingStepFlow.advance(first, response: invalid, hasResponse: true, choose: choose, call: call)
      XCTAssertEqual((try ConfirmedBilling.decode(retry)["input"] as? [String: Any])?["currentValue"] as? String, "300.00")
      let final = try await BillingStepFlow.advance(retry, response: "300.00", hasResponse: true, choose: choose, call: call)
      XCTAssertEqual(try ConfirmedBilling.decode(final)["status"] as? String, "confirmed")
      XCTAssertTrue(choices.isEmpty)
    }
  }

  // Text entry regressions: use the same orchestration as the public action.
  @available(iOS 16.0, *)
  @MainActor
  func testTextEntryReviewsAndCommitsOnlyAfterConfirmation() async throws {
    var choices = ["确认提交"]
    var sawReview = false
    var recognitions = 0
    var commits = 0
    let result = try await TextBillingEntry.run(text: "  午饭 300 元  ", configuration: [:], choose: { values, prompt in
      XCTAssertEqual(prompt, "确认支出信息")
      sawReview = true
      XCTAssertTrue(values.contains("备注：原文"))
      return self.menuValue(choices.removeFirst(), values)
    }, input: { _ in XCTFail("Complete text bill must not request input before review"); return "" }, call: { request in
      switch request["operation"] as? String {
      case "recognize":
        recognitions += 1
        XCTAssertEqual(request["mode"] as? String, "text")
        XCTAssertEqual(request["text"] as? String, "午饭 300 元")
        XCTAssertEqual(request["ledgerId"] as? Int, 1)
        XCTAssertNil(request["imagePath"])
        return try ConfirmedBilling.decode(self.editorDraft())
      case "validate": return ["status": "valid"]
      default: return self.editorOptions()
      }
    }, commit: { submission, attachment in
      XCTAssertTrue(sawReview)
      XCTAssertTrue(choices.isEmpty)
      XCTAssertEqual(submission["confirmed"] as? Bool, true)
      XCTAssertNil(attachment)
      commits += 1
      return "saved"
    })
    XCTAssertEqual(result, "saved")
    XCTAssertEqual(recognitions, 1)
    XCTAssertEqual(commits, 1)
  }

  @available(iOS 16.0, *)
  @MainActor
  func testTextEntryMissingFieldsShowsReviewBeforeAnyInputAndCanCancel() async throws {
    var sawReview = false
    do {
      _ = try await TextBillingEntry.run(text: "付款信息没有明确金额", configuration: [:], choose: { values, prompt in
        XCTAssertEqual(prompt, "确认支出信息")
        XCTAssertTrue(values.contains("金额：待填写"))
        XCTAssertTrue(values.contains("账户：待选择"))
        sawReview = true
        return "取消提交"
      }, input: { _ in XCTFail("Must show review before missing amount input"); return "" }, call: { request in
        if request["operation"] as? String == "recognize" {
          return ["status": "draft", "ledgerId": 1, "currency": "CNY", "candidates": [["type": "expense", "note": "待核对"]]]
        }
        XCTAssertEqual(request["operation"] as? String, "options")
        return self.editorOptions()
      }, commit: { _, _ in XCTFail("Cancelled bill cannot commit"); return "" })
      XCTFail("Expected cancellation")
    } catch { XCTAssertTrue(sawReview) }
  }

  @available(iOS 16.0, *)
  @MainActor
  func testTextEntryRecognitionFailureManualFallbackReachesReview() async throws {
    var sawFailure = false
    var sawReview = false
    do {
      _ = try await TextBillingEntry.run(text: "示例文字", configuration: [:], choose: { values, prompt in
        if values.contains("人工填写") {
          sawFailure = true
          XCTAssertTrue(prompt.contains("识别未完成"))
          return "人工填写"
        }
        XCTAssertTrue(sawFailure)
        XCTAssertEqual(prompt, "确认支出信息")
        sawReview = true
        return "取消提交"
      }, input: { _ in XCTFail("Fallback must show review before asking for amount"); return "" }, call: { request in
        if request["operation"] as? String == "recognize" { throw NSError(domain: "test-ai", code: 1) }
        XCTAssertEqual(request["operation"] as? String, "options")
        return self.editorOptions()
      }, commit: { _, _ in XCTFail("No commit before confirmation"); return "" })
      XCTFail("Expected cancellation")
    } catch { XCTAssertTrue(sawFailure); XCTAssertTrue(sawReview) }
  }

  @available(iOS 16.0, *)
  @MainActor
  func testTextEntryOptionsFailureShowsRetryAndDoesNotRepeatAI() async throws {
    var optionCalls = 0
    var recognitions = 0
    var choices = ["重试", "确认提交"]
    _ = try await TextBillingEntry.run(text: "午饭300元", configuration: [:], choose: { values, prompt in
      let action = choices.removeFirst()
      XCTAssertTrue(values.contains(action))
      if action == "重试" { XCTAssertTrue(prompt.contains("文字记账无法读取账本选项")) }
      return action
    }, input: { _ in XCTFail("Must not request text editing"); return "" }, call: { request in
      switch request["operation"] as? String {
      case "options":
        optionCalls += 1
        if optionCalls == 1 { throw NSError(domain: "test-bridge", code: 1) }
        return self.editorOptions()
      case "recognize": recognitions += 1; return try ConfirmedBilling.decode(self.editorDraft())
      case "validate": return ["status": "valid"]
      default: XCTFail("Unexpected request"); return [:]
      }
    }, commit: { _, _ in "saved" })
    XCTAssertEqual(recognitions, 1)
    XCTAssertTrue(choices.isEmpty)
  }

  @available(iOS 16.0, *)
  @MainActor
  func testTextEntryEmptySourceRejectedBeforeBridgeAndAI() async throws {
    XCTAssertEqual(TextBillingEntry.source(nil), "")
    XCTAssertEqual(TextBillingEntry.source(" \n \t"), "")
    var intent = TextConfirmBillingIntent()
    intent.text = " \n "
    do {
      _ = try await intent.perform()
      XCTFail("Empty source must throw a system parameter request")
    } catch {
      XCTAssertTrue(error is AppIntentError)
    }
    do {
      _ = try await TextBillingEntry.run(text: "  ", configuration: [:], choose: { _, _ in XCTFail(); return "" }, input: { _ in XCTFail(); return "" }, call: { _ in XCTFail("Empty input cannot reach bridge"); return [:] }, commit: { _, _ in XCTFail(); return "" })
      XCTFail("Empty input must not return success")
    } catch {}
  }

  @available(iOS 16.0, *)
  @MainActor
  func testTextEntryMissingAccountCannotCommitUntilSelectedAndReconfirmed() async throws {
    var choices = ["确认提交", "1. 支付宝", "确认提交"]
    var committed = false
    _ = try await TextBillingEntry.run(text: "消费300元", configuration: [:], choose: { values, _ in
      let action = choices.removeFirst()
      XCTAssertTrue(values.contains(action))
      XCTAssertFalse(committed)
      return action
    }, input: { _ in XCTFail(); return "" }, call: { request in
      if request["operation"] as? String == "recognize" {
        var draft = try ConfirmedBilling.decode(self.editorDraft())
        var candidates = try XCTUnwrap(draft["candidates"] as? [[String: Any]])
        candidates[0].removeValue(forKey: "accountId")
        draft["candidates"] = candidates
        return draft
      }
      return request["operation"] as? String == "validate" ? ["status": "valid"] : self.editorOptions()
    }, commit: { submission, _ in
      XCTAssertTrue(choices.isEmpty)
      XCTAssertEqual(submission["accountId"] as? Int, 1)
      committed = true
      return "saved"
    })
    XCTAssertTrue(committed)
  }

  @available(iOS 16.0, *)
  @MainActor
  func testTextEntryEditorOptionsRetryDoesNotRepeatRecognition() async throws {
    var optionCalls = 0
    var recognitions = 0
    var choices = ["重试", "确认提交"]
    _ = try await TextBillingEntry.run(text: "示例300元", configuration: [:], choose: { values, _ in
      let action = choices.removeFirst()
      XCTAssertTrue(values.contains(action))
      return action
    }, input: { _ in XCTFail(); return "" }, call: { request in
      switch request["operation"] as? String {
      case "options":
        optionCalls += 1
        if optionCalls == 2 { throw NSError(domain: "editor-options", code: 1) }
        return self.editorOptions()
      case "recognize": recognitions += 1; return try ConfirmedBilling.decode(self.editorDraft())
      case "validate": return ["status": "valid"]
      default: XCTFail(); return [:]
      }
    }, commit: { _, _ in "saved" })
    XCTAssertEqual(recognitions, 1)
    XCTAssertTrue(choices.isEmpty)
  }

  // Diagnostic seam tests verify stage reporting/error identity, not the
  // Shortcuts host UI. They must not be reported as keyboard acceptance tests.
  @available(iOS 16.0, *)
  @MainActor
  func testInputTraceReportsReturnedEmptyStringWithoutLoggingNote() async throws {
    var events: [String] = []
    let value = try await ConfirmedBilling.tracedInput({ "" }, trace: { events.append($0) })
    XCTAssertEqual(value, "")
    XCTAssertEqual(events, ["request.started", "request.returned"])
    events = []
    let privateValue = try await ConfirmedBilling.tracedInput({ "private bill note" }, trace: { events.append($0) })
    XCTAssertEqual(privateValue, "private bill note")
    XCTAssertFalse(events.joined().contains("private"))
  }

  @available(iOS 16.0, *)
  @MainActor
  func testInputTraceReportsCancellationAndRethrows() async throws {
    var events: [String] = []
    do {
      _ = try await ConfirmedBilling.tracedInput({ throw CancellationError() }, trace: { events.append($0) })
      XCTFail("Cancellation must not become empty note or success")
    } catch { XCTAssertTrue(error is CancellationError) }
    XCTAssertEqual(events.first, "request.started")
    XCTAssertTrue(events.last?.hasPrefix("request.cancelled code=") == true)
    XCTAssertEqual(events.count, 2)
  }

  @available(iOS 16.0, *)
  @MainActor
  func testInputTraceReportsFrameworkErrorWithoutReplacingIt() async throws {
    let intent = TextConfirmBillingIntent()
    let original = intent.$text.needsValueError("private prompt")
    var events: [String] = []
    do {
      _ = try await ConfirmedBilling.tracedInput({ throw original }, trace: { events.append($0) })
      XCTFail("Framework error must propagate through diagnostic seam")
    } catch { XCTAssertTrue(error is AppIntentError) }
    XCTAssertTrue(events.last?.hasPrefix("request.framework code=") == true)
    XCTAssertFalse(events.joined().contains("private"))
  }

  @available(iOS 16.0, *)
  @MainActor
  func testInputTraceReportsErrorCodeWithoutLoggingErrorDescription() async throws {
    let original = NSError(domain: "TestInput", code: 42, userInfo: [NSLocalizedDescriptionKey: "private note content"])
    var events: [String] = []
    do {
      _ = try await ConfirmedBilling.tracedInput({ throw original }, trace: { events.append($0) })
      XCTFail("Error must propagate through diagnostic seam")
    } catch {
      XCTAssertEqual((error as NSError).domain, original.domain)
      XCTAssertEqual((error as NSError).code, 42)
    }
    XCTAssertEqual(events, ["request.started", "request.error code=42"])
    XCTAssertFalse(events.joined().contains("private"))
  }

  // Handoff tests inject menu/AI/store responses. They verify state and result
  // routing, not system parameter presentation, keyboard prefill or host chaining.
  @available(iOS 16.0, *)
  @MainActor
  func testHandoffRepeatedNoteAndAmountKeepsOneDraftAndSingleFinalCommit() async throws {
    var choices = ["备注", "备注", "金额", "确认提交"]
    var commits = 0
    let draft = try editorDraft()
    let requestID = try XCTUnwrap(ConfirmedBilling.decode(draft)["requestId"] as? String)
    let choose: ([String], String) async throws -> String = { values, _ in
      let action = self.menuValue(choices.removeFirst(), values)
      XCTAssertTrue(values.contains(action)); return action
    }
    let call: ([String: Any]) async throws -> [String: Any] = { request in
      XCTAssertNotEqual(request["operation"] as? String, "recognize")
      XCTAssertNotEqual(request["operation"] as? String, "commit")
      return request["operation"] as? String == "validate" ? ["status": "valid"] : self.editorOptions()
    }
    let commit: ([String: Any], IntentFile?) async throws -> String = { submission, _ in
      commits += 1
      XCTAssertEqual(submission["requestId"] as? String, requestID)
      XCTAssertEqual(submission["originalAmountMinor"] as? Int, 12345)
      XCTAssertEqual((submission["entries"] as? [[String: Any]])?.first?["note"] as? String, "最终备注")
      return "saved"
    }
    var outcome = try await BillingHandoff.advance(BillingStepFlow.start(draft), choose: choose, call: call, commit: commit)
    for (index, answer) in ["第一次", "最终备注", "123.45"].enumerated() {
      guard case let .input(state, request) = outcome else { XCTFail("Expected input"); return }
      XCTAssertEqual(request.currentValue, ["原文", "第一次", "300.00"][index])
      XCTAssertEqual(request.inputType, index == 2 ? "number" : "text")
      XCTAssertEqual(commits, 0)
      outcome = try await BillingHandoff.advance(state, response: answer, hasResponse: true, choose: choose, call: call, commit: commit)
    }
    guard case let .finished(saved) = outcome else { XCTFail("Expected final save"); return }
    XCTAssertEqual(saved, "saved")
    XCTAssertEqual(commits, 1)
    XCTAssertTrue(choices.isEmpty)
  }

  @available(iOS 16.0, *)
  @MainActor
  func testHandoffSplitResumesDetailAndPreservesIndependentNotes() async throws {
    var choices = ["拆分或新增明细", "金额", "备注", "完成此笔", "拆分或新增明细", "完成此笔",
      "编辑明细", "第 1 笔 80.00", "备注", "完成此笔", "确认提交"]
    let choose: ([String], String) async throws -> String = { values, _ in
      let action = self.menuValue(choices.removeFirst(), values)
      XCTAssertTrue(values.contains(action)); return action
    }
    let call: ([String: Any]) async throws -> [String: Any] = { request in
      XCTAssertNotEqual(request["operation"] as? String, "recognize")
      return request["operation"] as? String == "validate" ? ["status": "valid"] : self.editorOptions()
    }
    var commits = 0
    let commit: ([String: Any], IntentFile?) async throws -> String = { submission, _ in
      commits += 1
      let entries = try XCTUnwrap(submission["entries"] as? [[String: Any]])
      XCTAssertEqual(entries.compactMap { $0["amountMinor"] as? Int }, [8000, 22000])
      XCTAssertEqual(entries[0]["note"] as? String, "只改第一笔")
      XCTAssertEqual(entries[1]["note"] as? String, "原文")
      return "saved"
    }
    var outcome = try await BillingHandoff.advance(BillingStepFlow.start(editorDraft()), choose: choose, call: call, commit: commit)
    for (index, answer) in ["80", "第一笔", "只改第一笔"].enumerated() {
      guard case let .input(state, request) = outcome else { XCTFail("Expected nested input"); return }
      XCTAssertEqual(request.currentValue, ["300.00", "原文", "第一笔"][index])
      outcome = try await BillingHandoff.advance(state, response: answer, hasResponse: true, choose: choose, call: call, commit: commit)
    }
    guard case .finished = outcome else { XCTFail("Expected final save"); return }
    XCTAssertEqual(commits, 1)
    XCTAssertTrue(choices.isEmpty)
  }

  @available(iOS 16.0, *)
  @MainActor
  func testHandoffCancellationNeverCallsCommitAndNoTerminalOpenIntent() async throws {
    let outcome = try await BillingHandoff.advance(BillingStepFlow.start(editorDraft()), choose: { _, _ in "取消提交" }, call: { _ in self.editorOptions() }, commit: { _, _ in XCTFail("Cancel cannot commit"); return "" })
    guard case .cancelled = outcome else { XCTFail("Expected cancel"); return }
    let terminal = try BillingHandoff.result(outcome, attachment: nil)
    XCTAssertNil(terminal.opensIntent)
    XCTAssertNotNil(terminal.dialog)
    let stopped = try await BillingHandoff.advance(BillingStepFlow.start(editorDraft()), choose: { _, _ in throw CancellationError() }, call: { _ in self.editorOptions() }, commit: { _, _ in XCTFail(); return "" })
    guard case .cancelled = stopped else { XCTFail("Host cancellation must not commit"); return }
  }

  @available(iOS 16.0, *)
  @MainActor
  func testHandoffCarriesAttachmentAndReferenceButDoesNotPresetRequiredInput() async throws {
    let attachment = IntentFile(data: Data([1, 2, 3]), filename: "example.png", type: .png)
    let outcome = try await BillingHandoff.advance(BillingStepFlow.start(editorDraft()), attachment: attachment, choose: { values, _ in self.menuValue("备注", values) }, call: { _ in self.editorOptions() }, commit: { _, _ in XCTFail(); return "" })
    let result = try BillingHandoff.result(outcome, attachment: attachment)
    let input = try XCTUnwrap(result.opensIntent)
    XCTAssertEqual(input.currentValue, "原文")
    XCTAssertEqual(input.attachment?.data, attachment.data)
    XCTAssertNil(input.$value.defaultValue)
    XCTAssertFalse(BillingValueInputIntent.openAppWhenRun)
    guard case let .input(state, _) = outcome else { XCTFail(); return }
    _ = try await BillingHandoff.advance(state, response: "修改", hasResponse: true, attachment: attachment, choose: { _, _ in "确认提交" }, call: { request in request["operation"] as? String == "validate" ? ["status": "valid"] : self.editorOptions() }, commit: { _, received in
      XCTAssertEqual(received?.data, attachment.data)
      return try ConfirmedBilling.encode(["status": "committed", "count": 1, "totalAmountMinor": 30000])
    })
    let finished = try BillingHandoff.result(.finished(ConfirmedBilling.encode(["status": "committed", "count": 1, "totalAmountMinor": 30000])), attachment: nil)
    XCTAssertNil(finished.opensIntent)
  }

  @available(iOS 16.0, *)
  @MainActor
  func testTextPreparationForHandoffRecognizesOnceAndShowsIncompleteReview() async throws {
    var recognitions = 0
    var menus = 0
    let prepared = try await TextBillingEntry.run(text: "未标明金额的付款信息", configuration: [:], independentInput: true, choose: { _, _ in XCTFail("Preparation must not edit"); return "" }, input: { _ in XCTFail("No requestValue"); return "" }, call: { request in
      if request["operation"] as? String == "recognize" {
        recognitions += 1
        return ["status": "draft", "ledgerId": 1, "currency": "CNY", "candidates": [["type": "expense", "note": "保留"]]]
      }
      return self.editorOptions()
    }, commit: { _, _ in XCTFail("Preparation cannot commit"); return "" })
    let outcome = try await BillingHandoff.advance(prepared, choose: { values, prompt in
      menus += 1
      XCTAssertEqual(prompt, "确认支出信息")
      XCTAssertTrue(values.contains("金额：待填写"))
      return "取消提交"
    }, call: { request in XCTAssertEqual(request["operation"] as? String, "options"); return self.editorOptions() }, commit: { _, _ in XCTFail(); return "" })
    guard case .cancelled = outcome else { XCTFail(); return }
    XCTAssertEqual(recognitions, 1)
    XCTAssertEqual(menus, 1)
  }

  @available(iOS 16.0, *)
  @MainActor
  func testHandoffInvalidSplitAmountRequestsAgainWithoutCommit() async throws {
    var choices = ["拆分或新增明细", "金额", "返回修改", "金额"]
    let choose: ([String], String) async throws -> String = { values, _ in
      let action = self.menuValue(choices.removeFirst(), values)
      XCTAssertTrue(values.contains(action)); return action
    }
    let call: ([String: Any]) async throws -> [String: Any] = { _ in self.editorOptions() }
    let commit: ([String: Any], IntentFile?) async throws -> String = { _, _ in XCTFail("Invalid input cannot commit"); return "" }
    let first = try await BillingHandoff.advance(BillingStepFlow.start(editorDraft()), choose: choose, call: call, commit: commit)
    guard case let .input(state, _) = first else { XCTFail(); return }
    let retry = try await BillingHandoff.advance(state, response: "400", hasResponse: true, choose: choose, call: call, commit: commit)
    guard case let .input(next, request) = retry else { XCTFail(); return }
    XCTAssertEqual(request.currentValue, "300.00")
    let cancelled = try await BillingHandoff.advance(next, response: "80", hasResponse: true, choose: { values, _ in values.contains("取消本次字段修改") ? "取消本次字段修改" : "取消提交" }, call: call, commit: commit)
    // The detail cancellation returns to the original draft, not a saved row.
    // Stop the outer host request as well.
    guard case .cancelled = cancelled else { XCTFail("Must return to original draft then cancel, never save"); return }
    XCTAssertTrue(choices.isEmpty)
  }

  @available(iOS 16.0, *)
  @MainActor
  func testManualIncomeAndTransferHandoffDoesNotRecognizeAgain() async throws {
    for type in ["income", "transfer"] {
      var source = try ConfirmedBilling.decode(editorDraft(type))
      var candidates = try XCTUnwrap(source["candidates"] as? [[String: Any]])
      if type == "transfer" { candidates[0]["toAccountId"] = 2 }
      source["candidates"] = candidates
      var choices = ["备注", "确认提交"]
      let choose: ([String], String) async throws -> String = { values, _ in self.menuValue(choices.removeFirst(), values) }
      let call: ([String: Any]) async throws -> [String: Any] = { request in
        XCTAssertNotEqual(request["operation"] as? String, "recognize")
        return request["operation"] as? String == "validate" ? ["status": "valid"] : self.editorOptions(type)
      }
      let first = try await BillingHandoff.advance(BillingStepFlow.start(ConfirmedBilling.encode(source)), choose: choose, call: call, commit: { _, _ in XCTFail(); return "" })
      guard case let .input(state, _) = first else { XCTFail(); return }
      let result = try await BillingHandoff.advance(state, response: "手填修改", hasResponse: true, choose: choose, call: call, commit: { submission, _ in
        XCTAssertEqual(submission["type"] as? String, type)
        XCTAssertEqual((submission["entries"] as? [[String: Any]])?.first?["note"] as? String, "手填修改")
        return "saved"
      })
      guard case .finished = result else { XCTFail(); return }
      XCTAssertTrue(choices.isEmpty)
    }
  }

  @available(iOS 16.0, *)
  @MainActor
  func testFullAllocationAddSelectsExistingDetailThenContinuesSplitThroughHandoff() async throws {
    var choices = ["拆分或新增明细", "完成此笔", "拆分或新增明细", "第 1 笔 300.00", "金额", "备注", "完成此笔",
      "拆分或新增明细", "完成此笔", "确认提交"]
    var fullSelectionPrompts = 0
    var commits = 0
    let choose: ([String], String) async throws -> String = { values, prompt in
      XCTAssertFalse(values.contains("开始拆分"))
      if prompt.contains("金额已分配完") {
        fullSelectionPrompts += 1
        XCTAssertEqual(values, ["第 1 笔 300.00", "返回"])
      }
      let action = self.menuValue(choices.removeFirst(), values)
      XCTAssertTrue(values.contains(action), action); return action
    }
    let call: ([String: Any]) async throws -> [String: Any] = { request in
      XCTAssertNotEqual(request["operation"] as? String, "recognize")
      XCTAssertNotEqual(request["operation"] as? String, "commit")
      return request["operation"] as? String == "validate" ? ["status": "valid"] : self.editorOptions()
    }
    let commit: ([String: Any], IntentFile?) async throws -> String = { submission, _ in
      commits += 1
      XCTAssertTrue(choices.isEmpty)
      let entries = try XCTUnwrap(submission["entries"] as? [[String: Any]])
      XCTAssertEqual(entries.compactMap { $0["amountMinor"] as? Int }, [8000, 22000])
      XCTAssertEqual(entries[0]["note"] as? String, "第一笔")
      XCTAssertEqual(entries[1]["note"] as? String, "原文")
      XCTAssertEqual(entries[0]["categoryId"] as? Int, 10)
      XCTAssertEqual(entries[0]["tagIds"] as? [Int], [3])
      return "saved"
    }
    var outcome = try await BillingHandoff.advance(BillingStepFlow.start(editorDraft()), choose: choose, call: call, commit: commit)
    for (index, answer) in ["80", "第一笔"].enumerated() {
      guard case let .input(state, request) = outcome else { XCTFail("Expected detail input"); return }
      XCTAssertEqual(request.currentValue, index == 0 ? "300.00" : "原文")
      XCTAssertEqual(commits, 0)
      outcome = try await BillingHandoff.advance(state, response: answer, hasResponse: true, choose: choose, call: call, commit: commit)
    }
    guard case .finished = outcome else { XCTFail("Expected confirmed save"); return }
    XCTAssertEqual(commits, 1)
    XCTAssertEqual(fullSelectionPrompts, 1, "Historical selector must not redisplay after input")
    XCTAssertTrue(choices.isEmpty)
  }

  @available(iOS 16.0, *)
  @MainActor
  func testFullAllocationSelectorReturnAndFieldCancelPreserveOriginalDetail() async throws {
    for cancelField in [false, true] {
      var choices = ["拆分或新增明细", "完成此笔", "拆分或新增明细"] +
        (cancelField ? ["第 1 笔 300.00", "备注", "取消本次字段修改"] : ["返回"]) + ["确认提交"]
      var sawSelector = false
      let editor = ConfirmedBillingEditor(draft: try editorDraft(), choose: { values, prompt in
        if prompt.contains("金额已分配完") { sawSelector = true }
        let action = self.menuValue(choices.removeFirst(), values)
        XCTAssertTrue(values.contains(action)); return action
      }, input: { _ in
        XCTAssertTrue(cancelField)
        return "不应保留的编辑"
      }, call: { request in request["operation"] as? String == "validate" ? ["status": "valid"] : self.editorOptions() })
      let submission = try ConfirmedBilling.decode(await editor.runEditor())
      let entries = try XCTUnwrap(submission["entries"] as? [[String: Any]])
      XCTAssertTrue(sawSelector)
      XCTAssertEqual(entries.count, 1)
      XCTAssertEqual(entries[0]["amountMinor"] as? Int, 30000)
      XCTAssertEqual(entries[0]["note"] as? String, "原文")
      XCTAssertTrue(choices.isEmpty)
    }
  }

  @available(iOS 16.0, *)
  @MainActor
  func testOverallocatedAddSelectsExistingDetailAndUsesCurrentTotalLimit() async throws {
    var choices = ["拆分或新增明细", "完成此笔", "修改原付款金额", "拆分或新增明细", "第 1 笔 300.00",
      "金额", "完成此笔", "拆分或新增明细", "完成此笔", "确认提交"]
    var inputs = ["250", "200"]
    var sawExcessSelector = false
    let editor = ConfirmedBillingEditor(draft: try editorDraft(), choose: { values, prompt in
      if prompt.contains("明细已超额 50.00") { sawExcessSelector = true }
      let action = self.menuValue(choices.removeFirst(), values)
      XCTAssertTrue(values.contains(action)); return action
    }, input: { _ in inputs.removeFirst() }, call: { request in request["operation"] as? String == "validate" ? ["status": "valid"] : self.editorOptions() })
    let submission = try ConfirmedBilling.decode(await editor.runEditor())
    let entries = try XCTUnwrap(submission["entries"] as? [[String: Any]])
    XCTAssertTrue(sawExcessSelector)
    XCTAssertEqual(submission["originalAmountMinor"] as? Int, 25000)
    XCTAssertEqual(entries.compactMap { $0["amountMinor"] as? Int }, [20000, 5000])
    XCTAssertTrue(choices.isEmpty)
    XCTAssertTrue(inputs.isEmpty)
  }

  @available(iOS 16.0, *)
  @MainActor
  func testSplitEntryLimitGivesFeedbackWithoutCreatingExtraDetail() async throws {
    var choices: [String] = []
    for _ in 0..<100 { choices += ["拆分或新增明细", "金额", "完成此笔"] }
    choices += ["拆分或新增明细", "返回账单", "确认提交", "返回修改", "取消提交"]
    var inputs = 0
    var sawLimit = false
    var sawUnallocated = false
    let editor = ConfirmedBillingEditor(draft: try editorDraft(), choose: { values, prompt in
      if prompt.contains("最多支持 100 笔明细") { sawLimit = true; XCTAssertEqual(values, ["返回账单"]) }
      if prompt.contains("金额尚未分配完") { sawUnallocated = true }
      let action = self.menuValue(choices.removeFirst(), values)
      XCTAssertTrue(values.contains(action)); return action
    }, input: { _ in inputs += 1; return "1" }, call: { request in
      XCTAssertEqual(request["operation"] as? String, "options", "Unallocated draft must not validate/save")
      return self.editorOptions()
    })
    do { _ = try await editor.runEditor(); XCTFail("Expected cancel") }
    catch { XCTAssertTrue(sawLimit); XCTAssertTrue(sawUnallocated) }
    XCTAssertEqual(inputs, 100)
    XCTAssertTrue(choices.isEmpty)
  }

  @available(iOS 16.0, *)
  @MainActor
  func testMissingOriginalAmountCannotSilentlyOpenSplitOrSave() async throws {
    var source = try ConfirmedBilling.decode(editorDraft())
    var candidates = try XCTUnwrap(source["candidates"] as? [[String: Any]])
    candidates[0].removeValue(forKey: "amountMinor")
    source["candidates"] = candidates
    var choices = ["拆分或新增明细", "返回账单", "取消提交"]
    var sawMissingAmount = false
    let editor = ConfirmedBillingEditor(draft: try ConfirmedBilling.encode(source), choose: { values, prompt in
      if prompt.contains("请先填写有效的原付款金额") { sawMissingAmount = true }
      let action = self.menuValue(choices.removeFirst(), values)
      XCTAssertTrue(values.contains(action)); return action
    }, input: { _ in XCTFail("Must show missing amount message before input"); return "" }, showIncompleteDraft: true, call: { request in
      XCTAssertEqual(request["operation"] as? String, "options")
      return self.editorOptions()
    })
    do { _ = try await editor.runEditor(); XCTFail("Expected cancel") }
    catch { XCTAssertTrue(sawMissingAmount) }
    XCTAssertTrue(choices.isEmpty)
  }

  @available(iOS 16.0, *)
  @MainActor
  func testOverallocatedDetailWithoutPositiveRoomExplainsAndDoesNotDropOtherEntries() async throws {
    var choices = ["拆分或新增明细", "金额", "完成此笔", "拆分或新增明细", "完成此笔", "修改原付款金额",
      "拆分或新增明细", "第 1 笔 80.00", "返回账单", "修改原付款金额", "确认提交"]
    var inputs = ["80", "50", "300"]
    var sawNoRoom = false
    let editor = ConfirmedBillingEditor(draft: try editorDraft(), choose: { values, prompt in
      if prompt.contains("其他明细已用完或超过总额") { sawNoRoom = true; XCTAssertEqual(values, ["返回账单"]) }
      let action = self.menuValue(choices.removeFirst(), values)
      XCTAssertTrue(values.contains(action)); return action
    }, input: { _ in inputs.removeFirst() }, call: { request in request["operation"] as? String == "validate" ? ["status": "valid"] : self.editorOptions() })
    let submission = try ConfirmedBilling.decode(await editor.runEditor())
    let entries = try XCTUnwrap(submission["entries"] as? [[String: Any]])
    XCTAssertTrue(sawNoRoom)
    XCTAssertEqual(entries.compactMap { $0["amountMinor"] as? Int }, [8000, 22000])
    XCTAssertEqual(submission["originalAmountMinor"] as? Int, 30000)
    XCTAssertTrue(inputs.isEmpty)
    XCTAssertTrue(choices.isEmpty)
  }


  // Variable billing regressions exercise the same two-action orchestration as perform().
  // Mock input proves state/save semantics, not Shortcuts keyboard presentation.
  @available(iOS 16.0, *)
  @MainActor
  private func variableBill(amount: String? = "300", type: String = "支出", category: String? = "食品",
                            tag: String? = "个人", account: Int? = 1, date: Date? = Date(timeIntervalSince1970: 1793853165),
                            note: String = "原备注", excluded: String? = "是", originalText: String = "原始付款文本") async throws -> VariableBillingDraft {
    try await VariableBillingFlow.prepare(amount: amount, type: type, ledgerId: 1, category: category, tag: tag,
        accountId: account, sourceAccountId: 1, destinationAccountId: 2, date: date, note: note, excluded: excluded,
        originalText: originalText, screenshot: nil, call: { request in
          XCTAssertNotEqual(request["operation"] as? String, "recognize")
          if request["operation"] as? String == "classify" { return ["categoryId": 11] }
          return self.variableOptions(request["type"] as? String ?? "expense", ledger: request["ledgerId"] as? Int ?? 1)
        })
  }
  @available(iOS 16.0, *)
  @MainActor
  private func variableOptions(_ type: String = "expense", ledger: Int = 1) -> [String: Any] {
    var result = editorOptions(type, ledger: ledger)
    let categories: [[String: Any]] = type == "expense" ? [["id": 11, "name": "餐饮/食品", "leafName": "食品", "parentId": 10, "parentName": "餐饮"],
        ["id": 12, "name": "餐饮/饮料", "leafName": "饮料", "parentId": 10, "parentName": "餐饮"]] : type == "income" ? [["id": 20, "name": "工资", "leafName": "工资"]] : []
    result["categories"] = categories
    return result
  }
  @available(iOS 16.0, *)
  @MainActor
  func testVariablePreparationMapsBareChildAndPreservesActualValuesWithoutCommit() async throws {
    var operations: [String] = []
    let image = IntentFile(data: Data([1, 2, 3]), filename: "payment.png", type: .png)
    let time = Date(timeIntervalSince1970: 1793853165)
    let bill = try await VariableBillingFlow.prepare(amount: "12.30", type: "支出", ledgerId: 1, category: "食品", tag: "个人",
        accountId: 1, sourceAccountId: 2, destinationAccountId: 2, date: time, note: "实际备注文字", excluded: "是",
        originalText: "不能覆盖备注的原文", screenshot: image, call: { request in
          operations.append(request["operation"] as? String ?? "")
          return self.variableOptions()
        })
    let object = try ConfirmedBilling.decode(bill.payload)
    XCTAssertEqual(operations, ["options"])
    XCTAssertEqual(object["amountMinor"] as? Int, 1230)
    XCTAssertEqual(object["categoryId"] as? Int, 11, "Bare child name must save its own ID, not its parent")
    XCTAssertEqual(object["tagIds"] as? [Int], [3])
    XCTAssertEqual(object["excludeFromBudget"] as? Bool, true)
    XCTAssertEqual(object["accountId"] as? Int, 1)
    XCTAssertNil(object["toAccountId"])
    XCTAssertEqual(object["note"] as? String, "实际备注文字")
    XCTAssertEqual(object["occurredAt"] as? String, ISO8601DateFormatter().string(from: time))
    XCTAssertEqual(bill.screenshot?.data, image.data)
    XCTAssertFalse(bill.payload.contains("dataBase64"))
    XCTAssertNil(object["confirmed"])
  }
  @available(iOS 16.0, *)
  @MainActor
  func testVariableAmbiguousNamesStayPendingAndNeverApplyRulesOverExplicitName() async throws {
    var options = variableOptions()
    var categories = options["categories"] as! [[String: Any]]
    categories.append(["id": 31, "name": "购物/食品", "leafName": "食品", "parentId": 30, "parentName": "购物"])
    options["categories"] = categories
    for name in ["食品", "不存在分类"] {
      let bill = try await VariableBillingFlow.prepare(amount: "1", type: "支出", ledgerId: 1, category: name, tag: "不存在标签",
          accountId: 1, sourceAccountId: nil, destinationAccountId: nil, date: nil, note: "规则命中也不能覆盖指定分类",
          excluded: "不是合法的是或否", originalText: "", screenshot: nil, call: { request in
            XCTAssertEqual(request["operation"] as? String, "options")
            return options
          })
      let object = try ConfirmedBilling.decode(bill.payload)
      XCTAssertNil(object["categoryId"])
      XCTAssertEqual(object["pendingCategory"] as? String, name)
      XCTAssertNotNil(object["pendingTag"])
      XCTAssertNotNil(object["pendingBudget"])
      XCTAssertNil(object["occurredAt"], "Missing time must not be silently replaced with now")
    }
    XCTAssertEqual(VariableBillingFlow.categoryMatches("餐饮/食品", options: categories).first?["id"] as? Int, 11)
  }
  @available(iOS 16.0, *)
  @MainActor
  func testVariableEmptyCategoryUsesLocalRulesOnlyAndExplicitCategoryNeverDoes() async throws {
    var operations: [String] = []
    let bill = try await VariableBillingFlow.prepare(amount: "1", type: "收入", ledgerId: 1, category: nil, tag: nil,
        accountId: 1, sourceAccountId: nil, destinationAccountId: nil, date: nil, note: "实际工资说明", excluded: "否",
        originalText: "工资到账", screenshot: nil, call: { request in
          operations.append(request["operation"] as? String ?? "")
          if request["operation"] as? String == "classify" {
            XCTAssertEqual(request["type"] as? String, "income")
            XCTAssertEqual(request["note"] as? String, "实际工资说明")
            XCTAssertEqual(request["ruleText"] as? String, "工资到账")
            return ["categoryId": 20]
          }
          return self.variableOptions("income")
        })
    XCTAssertEqual(operations, ["options", "classify"])
    XCTAssertEqual(try ConfirmedBilling.decode(bill.payload)["categoryId"] as? Int, 20)
  }
  @available(iOS 16.0, *)
  @MainActor
  func testVariableRepeatedAmountNoteEditsAndTagCyclesSaveOnlyLatestValues() async throws {
    let bill = try await variableBill()
    var actions = ["金额", "备注", "金额", "备注", "标签", "标签", "标签", "不计预算", "否", "分类", "1. 餐饮", "2. 餐饮/饮料", "确认提交"]
    var numbers = ["12.34", "23.45"]
    var notes = ["修改备注", "最终实际备注"]
    var commits = 0
    var sawFinal = false
    let outcome = try await VariableBillingFlow.review(bill, choose: { values, _ in
      if values.contains("确认提交") {
        XCTAssertFalse(values.contains { $0.contains("拆分") || $0.contains("不计收入") })
        if values.contains("金额：23.45 CNY") && values.contains("备注：最终实际备注") && values.contains("标签：家庭") && values.contains("不计预算：否") { sawFinal = true }
      }
      let desired = actions.removeFirst()
      let selected = values.first { $0 == desired || $0.hasPrefix(desired + "：") || $0 == "✓ " + desired } ?? desired
      XCTAssertTrue(values.contains(selected), selected)
      return selected
    }, readAmount: { _, _ in numbers.removeFirst() }, readNote: { current in
      XCTAssertEqual(current, notes.count == 2 ? "原备注" : "修改备注")
      return notes.removeFirst()
    }, readDate: { _ in XCTFail("No date edit"); return Date() }, call: { request in
      XCTAssertNotEqual(request["operation"] as? String, "recognize")
      return request["operation"] as? String == "validate" ? ["status": "valid"] : self.variableOptions()
    }, commit: { submission, attachment in
      commits += 1
      XCTAssertTrue(actions.isEmpty)
      XCTAssertTrue(sawFinal)
      XCTAssertEqual(submission["requestId"] as? String, try ConfirmedBilling.decode(bill.payload)["requestId"] as? String)
      let entry = try XCTUnwrap((submission["entries"] as? [[String: Any]])?.first)
      XCTAssertEqual(entry["amountMinor"] as? Int, 2345)
      XCTAssertEqual(entry["categoryId"] as? Int, 12)
      XCTAssertEqual(entry["note"] as? String, "最终实际备注")
      XCTAssertEqual(entry["tagIds"] as? [Int], [4])
      XCTAssertEqual(entry["excludeFromBudget"] as? Bool, false)
      XCTAssertNil(entry["excludeFromStats"])
      XCTAssertNil(attachment)
      return try ConfirmedBilling.encode(["status": "committed", "count": 1, "totalAmountMinor": 2345])
    })
    XCTAssertEqual(commits, 1)
    XCTAssertEqual(try ConfirmedBilling.decode(outcome.value)["status"] as? String, "committed")
    XCTAssertTrue(actions.isEmpty)
  }
  @available(iOS 16.0, *)
  @MainActor
  func testVariableInvalidAmountAndCancelledNoteKeepPreviousValuesThenAllowEmptyNote() async throws {
    let bill = try await variableBill()
    var actions = ["金额", "返回账单", "备注", "备注", "确认提交"]
    var noteCalls = 0
    _ = try await VariableBillingFlow.review(bill, choose: { values, _ in
      let desired = actions.removeFirst()
      return self.menuValue(desired, values)
    }, readAmount: { _, _ in "1.001" }, readNote: { _ in
      noteCalls += 1
      if noteCalls == 1 { throw CancellationError() }
      return ""
    }, readDate: { _ in Date() }, call: { request in
      request["operation"] as? String == "validate" ? ["status": "valid"] : self.variableOptions()
    }, commit: { submission, _ in
      let entry = try XCTUnwrap((submission["entries"] as? [[String: Any]])?.first)
      XCTAssertEqual(entry["amountMinor"] as? Int, 30000)
      XCTAssertEqual(entry["note"] as? String, "")
      return try ConfirmedBilling.encode(["status": "committed"])
    })
    XCTAssertEqual(noteCalls, 2)
    XCTAssertTrue(actions.isEmpty)
    XCTAssertThrowsError(try VariableBillingFlow.amountText(1.001, digits: 2))
    XCTAssertEqual(try VariableBillingFlow.amountText(12.30, digits: 2), "12.3")
  }
  @available(iOS 16.0, *)
  @MainActor
  func testVariableMissingFieldsShowReviewAndCannotSaveUntilFilled() async throws {
    let bill = try await variableBill(amount: nil, account: nil, date: nil)
    var actions = ["确认提交", "返回账单", "金额", "账户", "1. 支付宝", "时间", "确认提交"]
    var first = true
    _ = try await VariableBillingFlow.review(bill, choose: { values, _ in
      if first {
        XCTAssertTrue(values.contains("金额：待填写 CNY"))
        XCTAssertTrue(values.contains("账户：待选择"))
        XCTAssertTrue(values.contains("时间：待填写"))
        first = false
      }
      return self.menuValue(actions.removeFirst(), values)
    }, readAmount: { _, _ in "0.01" }, readNote: { _ in XCTFail(); return "" }, readDate: { current in
      XCTAssertNil(current)
      return Date(timeIntervalSince1970: 1793853165)
    }, call: { request in request["operation"] as? String == "validate" ? ["status": "valid"] : self.variableOptions() }, commit: { submission, _ in
      XCTAssertTrue(actions.isEmpty)
      XCTAssertEqual(submission["originalAmountMinor"] as? Int, 1)
      XCTAssertEqual(submission["accountId"] as? Int, 1)
      return try ConfirmedBilling.encode(["status": "committed"])
    })
    XCTAssertTrue(actions.isEmpty)
  }
  @available(iOS 16.0, *)
  @MainActor
  func testVariableCancelAndHostCancellationNeverValidateOrCommit() async throws {
    for hostCancellation in [false, true] {
      let prepared = try await variableBill()
      let result = try await VariableBillingFlow.review(prepared, choose: { _, _ in
        if hostCancellation { throw CancellationError() }
        return "取消提交"
      }, readAmount: { _, _ in XCTFail(); return "" }, readNote: { _ in XCTFail(); return "" }, readDate: { _ in XCTFail(); return Date() }, call: { request in
        XCTAssertEqual(request["operation"] as? String, "options")
        return self.variableOptions()
      }, commit: { _, _ in XCTFail("Cancellation cannot save"); return "" })
      XCTAssertEqual(try ConfirmedBilling.decode(result.value)["status"] as? String, "cancelled")
    }
  }
  @available(iOS 16.0, *)
  @MainActor
  func testVariableTransferUsesDedicatedAccountsAndOmitsCategoryAndBudget() async throws {
    let bill = try await variableBill(type: "转账")
    let object = try ConfirmedBilling.decode(bill.payload)
    XCTAssertEqual(object["accountId"] as? Int, 1)
    XCTAssertEqual(object["toAccountId"] as? Int, 2)
    _ = try await VariableBillingFlow.review(bill, choose: { values, _ in
      XCTAssertFalse(values.contains { $0.hasPrefix("账户：") || $0.hasPrefix("分类：") || $0.hasPrefix("不计预算：") })
      XCTAssertTrue(values.contains("转出账户：支付宝"))
      XCTAssertTrue(values.contains("转入账户：银行卡"))
      return "确认提交"
    }, readAmount: { _, _ in "" }, readNote: { _ in "" }, readDate: { _ in Date() }, call: { request in request["operation"] as? String == "validate" ? ["status": "valid"] : self.variableOptions("transfer") }, commit: { submission, _ in
      XCTAssertEqual(submission["accountId"] as? Int, 1)
      XCTAssertEqual(submission["toAccountId"] as? Int, 2)
      let entry = try XCTUnwrap((submission["entries"] as? [[String: Any]])?.first)
      XCTAssertNil(entry["categoryId"])
      XCTAssertEqual(entry["excludeFromBudget"] as? Bool, false)
      return try ConfirmedBilling.encode(["status": "committed"])
    })
  }
  @available(iOS 16.0, *)
  @MainActor
  func testVariableRetryUsesIdenticalFinalSubmissionAndQueriesOriginalID() async throws {
    let bill = try await variableBill()
    var commits: [String] = []
    var queries = 0
    _ = try await VariableBillingFlow.review(bill, choose: { values, _ in
      values.contains("确认提交") ? "确认提交" : "查询并重试原账单"
    }, readAmount: { _, _ in "" }, readNote: { _ in "" }, readDate: { _ in Date() }, call: { request in
      switch request["operation"] as? String {
      case "validate": return ["status": "valid"]
      case "query": queries += 1; return ["status": "not_found"]
      default: return self.variableOptions()
      }
    }, commit: { submission, _ in
      commits.append(try ConfirmedBilling.encode(submission))
      if commits.count == 1 { throw CocoaError(.fileWriteUnknown) }
      return try ConfirmedBilling.encode(["status": "committed"])
    })
    XCTAssertEqual(queries, 1)
    XCTAssertEqual(commits.count, 2)
    XCTAssertEqual(commits.first, commits.last)
  }


  @available(iOS 16.0, *)
  @MainActor
  func testVariableTypeAndLedgerEditsKeepLatestNoteAndRequireMatchingCategory() async throws {
    let bill = try await variableBill()
    var actions = ["备注", "账本", "2. 家庭", "类型", "收入", "分类", "1. 工资", "确认提交"]
    _ = try await VariableBillingFlow.review(bill, choose: { values, _ in
      let desired = actions.removeFirst()
      let selected = values.first { $0 == desired || $0.hasPrefix(desired + "：") || $0 == "✓ " + desired } ?? desired
      XCTAssertTrue(values.contains(selected), selected)
      return selected
    }, readAmount: { _, _ in XCTFail(); return "" }, readNote: { _ in "跨账本后也不能丢的备注" }, readDate: { _ in XCTFail(); return Date() }, call: { request in
      if request["operation"] as? String == "validate" { return ["status": "valid"] }
      XCTAssertEqual(request["operation"] as? String, "options", "Must never reclassify after manual editing")
      return self.variableOptions(request["type"] as? String ?? "expense", ledger: request["ledgerId"] as? Int ?? 1)
    }, commit: { submission, _ in
      XCTAssertEqual(submission["ledgerId"] as? Int, 2)
      XCTAssertEqual(submission["type"] as? String, "income")
      let entry = try XCTUnwrap((submission["entries"] as? [[String: Any]])?.first)
      XCTAssertEqual(entry["note"] as? String, "跨账本后也不能丢的备注")
      XCTAssertEqual(entry["categoryId"] as? Int, 20)
      XCTAssertEqual(entry["excludeFromBudget"] as? Bool, false)
      return try ConfirmedBilling.encode(["status": "committed"])
    })
    XCTAssertTrue(actions.isEmpty)
  }
  @available(iOS 16.0, *)
  @MainActor
  func testVariableCurrencyChangeNeverConvertsAmountSilently() async throws {
    let bill = try await variableBill()
    var actions = ["账本", "2. 家庭", "切换并重新填写金额", "金额", "确认提交"]
    var newCurrency = false
    _ = try await VariableBillingFlow.review(bill, choose: { values, _ in
      if values.contains("确认提交") && newCurrency {
        XCTAssertTrue(values.contains { $0.hasPrefix("金额：") && $0.hasSuffix(" JPY") })
      }
      let desired = actions.removeFirst()
      return self.menuValue(desired, values)
    }, readAmount: { current, digits in
      XCTAssertEqual(current, "待填写")
      XCTAssertEqual(digits, 0)
      return "100"
    }, readNote: { _ in XCTFail(); return "" }, readDate: { _ in XCTFail(); return Date() }, call: { request in
      if request["operation"] as? String == "validate" { return ["status": "valid"] }
      let ledger = request["ledgerId"] as? Int ?? 1
      var options = self.variableOptions(ledger: ledger)
      if ledger == 2 { options["currency"] = "JPY"; options["minorDigits"] = 0; newCurrency = true }
      return options
    }, commit: { submission, _ in
      XCTAssertEqual(submission["currency"] as? String, "JPY")
      XCTAssertEqual(submission["originalAmountMinor"] as? Int, 100)
      XCTAssertEqual(submission["ledgerId"] as? Int, 2)
      return try ConfirmedBilling.encode(["status": "committed"])
    })
    XCTAssertTrue(actions.isEmpty)
  }
  @available(iOS 16.0, *)
  @MainActor
  func testVariableScreenshotTravelsWithEntityAndEntersOnlyConfirmedSubmission() async throws {
    let renderer = UIGraphicsImageRenderer(size: CGSize(width: 8, height: 8))
    let data = try XCTUnwrap(renderer.image { _ in UIColor.orange.setFill(); UIRectFill(CGRect(x: 0, y: 0, width: 8, height: 8)) }.pngData())
    let image = IntentFile(data: data, filename: "payment.png", type: .png)
    let prepared = try await variableBill()
    let bill = VariableBillingDraft(payload: prepared.payload, screenshot: image)
    var commits = 0
    _ = try await VariableBillingFlow.review(bill, choose: { _, _ in "确认提交" }, readAmount: { _, _ in "" }, readNote: { _ in "" }, readDate: { _ in Date() }, call: { request in
      if request["operation"] as? String == "validate" {
        XCTAssertNil((request["submission"] as? [String: Any])?["attachment"], "Attachment not encoded before confirmation validation")
        return ["status": "valid"]
      }
      return self.variableOptions()
    }, commit: { submission, attachment in
      commits += 1
      XCTAssertNil(attachment, "Already encoded once, do not regenerate while retrying")
      let payload = try XCTUnwrap(submission["attachment"] as? [String: Any])
      let base64 = try XCTUnwrap(payload["dataBase64"] as? String)
      XCTAssertNotNil(Data(base64Encoded: base64))
      XCTAssertEqual((submission["entries"] as? [[String: Any]])?.count, 1)
      return try ConfirmedBilling.encode(["status": "committed"])
    })
    XCTAssertEqual(commits, 1)
  }
  @available(iOS 16.0, *)
  @MainActor
  func testVariableUnknownCommitStopsWithoutEditingOrChangingRequest() async throws {
    let bill = try await variableBill()
    var commits = 0
    let outcome = try await VariableBillingFlow.review(bill, choose: { values, _ in
      values.contains("确认提交") ? "确认提交" : "结束并稍后核对"
    }, readAmount: { _, _ in "" }, readNote: { _ in "" }, readDate: { _ in Date() }, call: { request in request["operation"] as? String == "validate" ? ["status": "valid"] : self.variableOptions() }, commit: { _, _ in
      commits += 1
      throw CocoaError(.fileWriteUnknown)
    })
    XCTAssertEqual(commits, 1)
    let result = try ConfirmedBilling.decode(outcome.value)
    XCTAssertEqual(result["status"] as? String, "unknown")
    XCTAssertEqual(result["requestId"] as? String, try ConfirmedBilling.decode(bill.payload)["requestId"] as? String)
  }


  @available(iOS 16.0, *)
  @MainActor
  func testVariableReceiptForSameIDCannotBypassFinalContentConflict() async throws {
    let bill = try await variableBill()
    var choices = ["确认提交", "查询并重试原账单", "结束并稍后核对"]
    var commits = 0
    let outcome = try await VariableBillingFlow.review(bill, choose: { values, _ in
      let selected = choices.removeFirst()
      XCTAssertTrue(values.contains(selected))
      return selected
    }, readAmount: { _, _ in "" }, readNote: { _ in "" }, readDate: { _ in Date() }, call: { request in
      switch request["operation"] as? String {
      case "validate": return ["status": "valid"]
      case "query": return ["status": "committed", "totalAmountMinor": 1]
      default: return self.variableOptions()
      }
    }, commit: { _, _ in
      commits += 1
      throw CocoaError(.fileWriteFileExists)
    })
    XCTAssertEqual(commits, 2, "Must recheck canonical payload even if a receipt with this ID exists")
    XCTAssertEqual(try ConfirmedBilling.decode(outcome.value)["status"] as? String, "unknown")
    XCTAssertTrue(choices.isEmpty)
  }


  // This seam is called by the live intent around requestValue. These are host-error
  // routing tests, not evidence that a Shortcuts input sheet appeared on a device.
  @available(iOS 16.0, *)
  @MainActor
  func testVariablePromptReturnsNumericAndEmptyTextWithoutLoggingValues() async throws {
    var events: [String] = []
    let amount: Double = try await VariableBillingPrompt.request(.amount, trace: { events.append($0) }) { 127.89 }
    let note: String = try await VariableBillingPrompt.request(.note, trace: { events.append($0) }) { "private real bill note" }
    let empty: String = try await VariableBillingPrompt.request(.note, trace: { events.append($0) }) { "" }
    XCTAssertEqual(amount, 127.89)
    XCTAssertEqual(note, "private real bill note")
    XCTAssertEqual(empty, "")
    XCTAssertEqual(events, ["variable.amount.requested", "variable.amount.returned",
        "variable.note.requested", "variable.note.returned", "variable.note.requested", "variable.note.returned"])
    XCTAssertFalse(events.joined().contains("127.89"))
    XCTAssertFalse(events.joined().contains("private"))
  }
  @available(iOS 16.0, *)
  @MainActor
  func testVariablePromptCancellationRemainsCancellationWithoutSyntheticValue() async throws {
    for field in [VariableBillingPrompt.Field.amount, .note] {
      var events: [String] = []
      do {
        let _: String = try await VariableBillingPrompt.request(field, trace: { events.append($0) }) { throw CancellationError() }
        XCTFail("Cancellation must not turn into an empty note or numeric zero")
      } catch { XCTAssertTrue(error is CancellationError) }
      XCTAssertEqual(events, ["variable." + field.rawValue + ".requested", "variable." + field.rawValue + ".cancelled"])
    }
  }
  @available(iOS 16.0, *)
  @MainActor
  func testVariablePromptHostErrorRetainsOriginalWithoutLoggingDescription() async throws {
    let original = NSError(domain: "InputHost", code: 42, userInfo: [NSLocalizedDescriptionKey: "private note and amount 127.89"])
    var events: [String] = []
    do {
      let _: String = try await VariableBillingPrompt.request(.note, trace: { events.append($0) }) { throw original }
      XCTFail("Failed input must not fabricate bill text")
    } catch let failure as VariableBillingPrompt.Failure {
      XCTAssertEqual((failure.underlying as NSError).domain, "InputHost")
      XCTAssertEqual((failure.underlying as NSError).code, 42)
    }
    XCTAssertEqual(events, ["variable.note.requested", "variable.note.host_error code=42"])
    XCTAssertFalse(events.joined().contains("private"))
    XCTAssertFalse(events.joined().contains("127.89"))
  }
  @available(iOS 16.0, *)
  @MainActor
  func testVariablePromptFrameworkErrorIsNotConsumedByBillValidationMenu() async throws {
    let intent = ConfirmVariableBillingIntent()
    let original = intent.$editingNote.needsValueError("private current note")
    let bill = try await variableBill()
    var events: [String] = []
    var menus = 0
    var validations = 0
    var commits = 0
    do {
      _ = try await VariableBillingFlow.review(bill, choose: { values, _ in
        menus += 1
        XCTAssertEqual(menus, 1, "Host errors must not trigger another bill-error menu")
        return self.menuValue("备注", values)
      }, readAmount: { _, _ in XCTFail(); return "" }, readNote: { _ in
        try await VariableBillingPrompt.request(.note, trace: { events.append($0) }) { throw original }
      }, readDate: { _ in XCTFail(); return Date() }, call: { request in
        if request["operation"] as? String == "validate" { validations += 1 }
        return self.variableOptions()
      }, commit: { _, _ in commits += 1; return "" })
      XCTFail("Framework error must unwind to perform for Shortcuts to handle")
    } catch let failure as VariableBillingPrompt.Failure {
      XCTAssertTrue(failure.underlying is AppIntentError)
    }
    XCTAssertEqual(menus, 1)
    XCTAssertEqual(validations, 0)
    XCTAssertEqual(commits, 0)
    XCTAssertTrue(events.last?.hasPrefix("variable.note.framework code=") == true)
    XCTAssertFalse(events.joined().contains("private"))
  }
  @available(iOS 16.0, *)
  @MainActor
  func testVariableNumericHostErrorCannotReachSubmitOrBusinessRetry() async throws {
    let bill = try await variableBill()
    let original = NSError(domain: "NumericHost", code: 17)
    var menus = 0
    do {
      _ = try await VariableBillingFlow.review(bill, choose: { values, _ in
        menus += 1
        XCTAssertEqual(menus, 1)
        return self.menuValue("金额", values)
      }, readAmount: { _, _ in
        let value: Double = try await VariableBillingPrompt.request(.amount, trace: { _ in }) { throw original }
        return try VariableBillingFlow.amountText(value, digits: 2)
      }, readNote: { _ in XCTFail(); return "" }, readDate: { _ in XCTFail(); return Date() }, call: { request in
        XCTAssertEqual(request["operation"] as? String, "options")
        return self.variableOptions()
      }, commit: { _, _ in XCTFail("No input, no commit"); return "" })
      XCTFail("Host failure cannot be turned into success")
    } catch let failure as VariableBillingPrompt.Failure {
      XCTAssertEqual((failure.underlying as NSError).domain, "NumericHost")
      XCTAssertEqual((failure.underlying as NSError).code, 17)
    }
    XCTAssertEqual(menus, 1)
  }


  @available(iOS 16.0, *)
  @MainActor
  func testVariablePromptValuesStillValidateAndReturnToSameDraft() async throws {
    let bill = try await variableBill()
    var choices = ["金额", "返回账单", "金额", "备注", "金额", "备注", "确认提交"]
    var amounts: [Double] = [1.001, 12.34, 23.45]
    var notes = ["第一次备注", "最后实际备注"]
    var events: [String] = []
    var commits = 0
    _ = try await VariableBillingFlow.review(bill, choose: { values, _ in
      let desired = choices.removeFirst()
      let selected = self.menuValue(desired, values)
      XCTAssertTrue(values.contains(selected), selected)
      return selected
    }, readAmount: { _, digits in
      let number: Double = try await VariableBillingPrompt.request(.amount, trace: { events.append($0) }) { amounts.removeFirst() }
      return try VariableBillingFlow.amountText(number, digits: digits)
    }, readNote: { current in
      XCTAssertEqual(current, notes.count == 2 ? "原备注" : "第一次备注")
      return try await VariableBillingPrompt.request(.note, trace: { events.append($0) }) { notes.removeFirst() }
    }, readDate: { _ in XCTFail(); return Date() }, call: { request in
      request["operation"] as? String == "validate" ? ["status": "valid"] : self.variableOptions()
    }, commit: { submission, _ in
      commits += 1
      XCTAssertTrue(choices.isEmpty)
      let entry = try XCTUnwrap((submission["entries"] as? [[String: Any]])?.first)
      XCTAssertEqual(entry["amountMinor"] as? Int, 2345)
      XCTAssertEqual(entry["note"] as? String, "最后实际备注")
      return try ConfirmedBilling.encode(["status": "committed"])
    })
    XCTAssertEqual(commits, 1)
    XCTAssertEqual(events.count, 10)
    XCTAssertTrue(amounts.isEmpty)
    XCTAssertTrue(notes.isEmpty)
    XCTAssertFalse(events.joined().contains("备注"))
  }

}
