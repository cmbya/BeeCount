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
  func testOnlyImageAndTextBillingActionsAreDiscoverable() {
    XCTAssertTrue(ImageConfirmBillingIntent.isDiscoverable)
    XCTAssertTrue(TextConfirmBillingIntent.isDiscoverable)
    XCTAssertFalse(BillingValueInputIntent.isDiscoverable)
    XCTAssertFalse(AutoBillingAppIntent.isDiscoverable)
    XCTAssertFalse(ImageConfirmBillingIntent.openAppWhenRun)
    XCTAssertFalse(TextConfirmBillingIntent.openAppWhenRun)
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

}
