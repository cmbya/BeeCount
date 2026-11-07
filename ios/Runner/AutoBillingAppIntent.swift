import Foundation
import UIKit
import ImageIO
import UniformTypeIdentifiers
import Vision

// 使用条件编译，只在iOS 16+编译AppIntents代码
#if canImport(AppIntents)
import AppIntents

/// 原生侧生成识别副本，避免 iOS 后台 Flutter channel 冻结影响附件保存。
struct ShortcutBillingImages {
    let attachment: URL
    let recognition: URL

    static func prepare(_ data: Data, keepOriginal: Bool, directory: URL) throws -> ShortcutBillingImages {
        guard let image = UIImage(data: data),
              let imageSource = CGImageSourceCreateWithData(data as CFData, nil) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        let timestamp = UUID().uuidString
        let recognitionPath = directory.appendingPathComponent("shortcut_recognition_\(timestamp).jpg")
        let pixelWidth = image.size.width * image.scale
        let pixelHeight = image.size.height * image.scale
        // 从图片源直接降采样，避免为了识别副本解码整张超长截图。
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: min(1920, max(pixelWidth, pixelHeight)),
        ]
        guard let thumbnail = CGImageSourceCreateThumbnailAtIndex(imageSource, 0, options as CFDictionary) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        let recognitionImage = UIImage(cgImage: thumbnail)
        guard let recognitionData = recognitionImage.jpegData(compressionQuality: 0.85) else {
            throw CocoaError(.fileWriteUnknown)
        }

        let typeIdentifier = CGImageSourceGetType(imageSource) as String?
        let fileExtension = keepOriginal
            ? (typeIdentifier.flatMap { UTType($0)?.preferredFilenameExtension } ?? "jpg")
            : "jpg"
        let attachmentPath = directory.appendingPathComponent("shortcut_screenshot_\(timestamp).\(fileExtension)")
        // 关闭开关时沿用原有 JPEG 质量；开启时直接保存传入字节。
        let attachmentData = keepOriginal ? data : image.jpegData(compressionQuality: 0.85)
        guard let attachmentData = attachmentData else {
            throw CocoaError(.fileWriteUnknown)
        }
        try attachmentData.write(to: attachmentPath)
        try recognitionData.write(to: recognitionPath)
        return ShortcutBillingImages(attachment: attachmentPath, recognition: recognitionPath)
    }
}

/// 蜜蜂记账 - 截图自动记账 AppIntent
/// 通过iOS快捷指令触发，实现截图后自动识别并记账
/// 仅iOS 16+可用，但App可在iOS 15+运行
///
/// openAppWhenRun = false:Shortcut 触发时不把 app 拉到前台。iOS 仍会
/// background-launch app 进程把 Flutter Engine 跑起来,AI 识别 + 落库
/// 全在后台完成,用户只感知到系统通知。
///
/// iOS 后台执行硬窗口 30 秒,实测 AI 视觉 + 落库 4-9 秒,留有余量。
/// 极端情况(网络抖动)若超时被 iOS kill,这张截图不会再被 Shortcut
/// 重试(Shortcut 已经把图传过来一次就走了),用户感知为「截图后没收到
/// 通知」,可手动改用相册记账兜底。
@available(iOS 16.0, *)
struct AutoBillingAppIntent: AppIntent {
    static var isDiscoverable: Bool = false
    static var title: LocalizedStringResource = "截图自动记账"
    static var description: LocalizedStringResource = "自动识别截图中的支付信息并创建账单"
    static var openAppWhenRun: Bool = false

    // 接收截图参数
    @Parameter(title: "截图")
    var screenshot: IntentFile?

    @MainActor
    func perform() async throws -> some IntentResult {
        // 如果快捷指令传递了图片，保存到临时目录
        if let screenshot = screenshot {
            print("[AppIntent] 收到截图参数，文件名: \(screenshot.filename)")

            // 尝试获取图片数据
            var imageData: Data?

            // 优先使用fileURL
            if let fileURL = screenshot.fileURL {
                print("[AppIntent] 从fileURL读取: \(fileURL.path)")
                imageData = try? Data(contentsOf: fileURL)
            }

            // 如果没有fileURL，尝试直接获取data
            if imageData == nil {
                print("[AppIntent] 尝试直接获取data属性")
                imageData = screenshot.data
            }

            // 如果都没有，尝试从filename构造路径
            if imageData == nil {
                print("[AppIntent] 尝试从filename读取: \(screenshot.filename)")
                let fileURL = URL(fileURLWithPath: screenshot.filename)
                imageData = try? Data(contentsOf: fileURL)
            }

            if let imageData = imageData {
                do {
                    let images = try ShortcutBillingImages.prepare(
                        imageData,
                        keepOriginal: UserDefaults.standard.bool(forKey: "flutter.attachmentKeepOriginal"),
                        directory: FileManager.default.temporaryDirectory
                    )
                    print("[AppIntent] 图片已保存到: \(images.attachment.path)")

                    // 分别传递识别副本和附件源文件，JSON 编码保留路径中的特殊字符。
                    let eventData = try JSONSerialization.data(withJSONObject: [
                        "action": "auto-billing",
                        "imagePath": images.attachment.path,
                        "recognitionImagePath": images.recognition.path,
                    ])
                    AppIntentsBridge.sendEvent(String(decoding: eventData, as: UTF8.self))
                    // 等 Flutter 完成附件保存和通知，避免后台进程提前退出。
                    await AppIntentsBridge.waitForBillingComplete()
                    return .result()
                } catch {
                    print("[AppIntent] 保存图片失败: \(error)")
                }
            } else {
                print("[AppIntent] 无法加载图片数据")
            }
        } else {
            print("[AppIntent] 未收到截图参数")
        }

        // 如果没有图片参数或处理失败，只发送事件（让Flutter端处理）
        let event = "{\"action\":\"auto-billing\"}"
        AppIntentsBridge.sendEvent(event)
        await AppIntentsBridge.waitForBillingComplete()
        return .result()
    }

    static var parameterSummary: some ParameterSummary {
        Summary("识别\(\.$screenshot)中的支付信息")
    }
}

/// Siri快捷语音指令配置（可选）
/// 用户可以对Siri说："在蜜蜂记账中截图记账"来触发
@available(iOS 16.0, *)
struct AutoBillingShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: PrepareVariableBillingIntent(), phrases: ["用\(.applicationName)准备账单"])
        AppShortcut(intent: ConfirmVariableBillingIntent(), phrases: ["用\(.applicationName)确认账单"])
    }
}
// MARK: - Shared image/text billing helpers

@available(iOS 16.0, *)
private struct ShortcutBillingError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

@available(iOS 16.0, *)
@MainActor
enum ConfirmedBilling {
    // Diagnostic transport deliberately preserves existing behavior. A simulated
    // input response cannot establish why the Shortcuts host dismisses its UI.
    static func tracedInput(_ read: () async throws -> String,
                            trace: (String) -> Void) async throws -> String {
        trace("request.started")
        do {
            let value = try await read()
            trace("request.returned")
            return value
        } catch {
            let kind = error is CancellationError ? "cancelled" : error is AppIntentError ? "framework" : "error"
            trace("request." + kind + " code=" + String((error as NSError).code))
            throw error
        }
    }

    static func inputTrace(_ event: String) {
        // Only fixed stage labels/codes, never prompts, notes, amounts or errors
        // descriptions. NSLog also helps when the Flutter log channel is suspended.
        let message = "[ShortcutInput] " + event
        NSLog("%@", message)
        LoggerPlugin.info(tag: "ShortcutInput", message: event)
    }

    static func requestText(_ parameter: IntentParameter<String>, prompt: String) async throws -> String {
        let token = UUID().uuidString
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown"
        inputTrace(token + " build=" + build + " ios=" + UIDevice.current.systemVersion + " host.state=" + String(UIApplication.shared.applicationState.rawValue) + " task.cancelled=" + String(Task.isCancelled))
        do {
            return try await tracedInput({ try await parameter.requestValue(IntentDialog(stringLiteral: prompt)) },
                trace: { inputTrace(token + " " + $0) })
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            // Kept unchanged until a device trace establishes the failure mode.
            throw ShortcutBillingError(message: "系统输入未完成，已保留原字段，请返回账单重试。" + error.localizedDescription)
        }
    }
    static func nextTag(_ current: [Int], tags: [[String: Any]]) -> [Int] {
        let ids = tags.compactMap { $0["id"] as? Int }
        guard !ids.isEmpty else { return [] }
        guard current.count == 1, let index = ids.firstIndex(of: current[0]) else { return [ids[0]] }
        return [ids[(index + 1) % ids.count]]
    }
    static func updatedNote(_ old: String, value: String?) -> String { value ?? old }
    static func encode(_ value: [String: Any]) throws -> String {
        String(decoding: try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]), as: UTF8.self)
    }
    static func decode(_ text: String) throws -> [String: Any] {
        guard let data = text.data(using: .utf8), data.count <= 1_000_000,
              let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ShortcutBillingError(message: "数据格式无效")
        }
        return object
    }
    static func call(_ payload: [String: Any]) async throws -> [String: Any] {
        // Recognition includes network upload and model inference. The short
        // persistence timeout must not cut it off while the AI client is waiting.
        let timeout: TimeInterval = payload["operation"] as? String == "recognize" ? 300 : 20
        let object = try decode(await AppIntentsBridge.request(payload, timeout: timeout))
        if object["status"] as? String == "error" {
            throw ShortcutBillingError(message: (object["message"] as? String ?? "操作失败") + " [" + (object["code"] as? String ?? "UNKNOWN") + "]")
        }
        return object
    }
    static func imageData(_ image: IntentFile) throws -> Data {
        let data = image.fileURL.flatMap { try? Data(contentsOf: $0) } ?? image.data
        guard !data.isEmpty, data.count <= 40_000_000 else { throw ShortcutBillingError(message: "图片为空或超过 40 MB") }
        return data
    }
    static func recognizeImage(_ image: IntentFile, ocr: Bool, configuration: String?) async throws -> [String: Any] {
        let data = try imageData(image)
        var input = try configuration.map(decode) ?? [:]
        input["operation"] = "recognize"
        input["timeZoneOffsetSeconds"] = TimeZone.current.secondsFromGMT()
        if ocr {
            let text = try await localText(data)
            input["mode"] = "text"
            input["text"] = text
            // No image path or bytes enter the text request.
            return try await call(input)
        }
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: 1920,
              ] as CFDictionary),
              let jpeg = UIImage(cgImage: thumbnail).jpegData(compressionQuality: 0.85) else {
            throw ShortcutBillingError(message: "无法读取图片")
        }
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("confirmed-billing-" + UUID().uuidString + ".jpg")
        // Clean up only our expired images left by process termination.
        if let files = try? FileManager.default.contentsOfDirectory(at: FileManager.default.temporaryDirectory, includingPropertiesForKeys: [.contentModificationDateKey]) {
            for file in files where file.lastPathComponent.hasPrefix("confirmed-billing-") && file.pathExtension == "jpg" {
                if let date = try? file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate,
                   Date().timeIntervalSince(date) > 3600 { try? FileManager.default.removeItem(at: file) }
            }
        }
        try jpeg.write(to: path, options: .atomic)
        defer { try? FileManager.default.removeItem(at: path) }
        input["mode"] = "image"
        input["imagePath"] = path.path
        // Local OCR supplements rules; this is still a vision AI request.
        let ruleText = try? await localText(data)
        input["ruleText"] = ruleText ?? ""
        var draft = try await call(input)
        if ruleText?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false {
            var candidates = draft["candidates"] as? [[String: Any]] ?? []
            for index in candidates.indices {
                var warnings = candidates[index]["warnings"] as? [String] ?? []
                warnings.append("本地取字未完成，全文分类规则可能未命中，请核对分类")
                candidates[index]["warnings"] = warnings
            }
            draft["candidates"] = candidates
        }
        return draft
    }
    static func localText(_ data: Data) async throws -> String {
        try await Task.detached {
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = true
            request.recognitionLanguages = ["zh-Hans", "en-US"]
            try VNImageRequestHandler(data: data).perform([request])
            let fragments = (request.results ?? []).compactMap { observation -> (text: String, box: CGRect)? in
                guard let candidate = observation.topCandidates(1).first else { return nil }
                return (candidate.string, observation.boundingBox)
            }
            return receiptText(fragments)
        }.value
    }
    // Vision may return labels before values. Reconstruct rows geometrically.
    nonisolated static func receiptText(_ fragments: [(text: String, box: CGRect)]) -> String {
        let sorted = fragments.filter { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && $0.box.height > 0 }.sorted {
            $0.box.midY == $1.box.midY ? $0.box.minX < $1.box.minX : $0.box.midY > $1.box.midY
        }
        var rows: [[(text: String, box: CGRect)]] = []
        for fragment in sorted {
            if let index = rows.firstIndex(where: { row in
                let anchor = row[0].box
                let overlap = min(anchor.maxY, fragment.box.maxY) - max(anchor.minY, fragment.box.minY)
                return overlap >= min(anchor.height, fragment.box.height) * 0.5 &&
                    abs(anchor.midY - fragment.box.midY) <= min(anchor.height, fragment.box.height) * 0.5
            }) { rows[index].append(fragment) }
            else { rows.append([fragment]) }
        }
        return rows.map { row in row.sorted { $0.box.minX < $1.box.minX }.map { $0.text }.joined(separator: "\t") }.joined(separator: "\n")
    }
    static func displayTime(_ value: String) -> String {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        guard let date = fractional.date(from: value) ?? ISO8601DateFormatter().date(from: value) else { return value }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter.string(from: date)
    }
    // Attachment is independent from recognition. Encode only after confirmation;
    // no permanent files or AI calls are made by this helper.
    static func attachmentPayload(_ attachment: IntentFile, keepOriginal override: Bool? = nil) throws -> [String: Any] {
        let data = try imageData(attachment)
        guard UIImage(data: data) != nil,
              let source = CGImageSourceCreateWithData(data as CFData, nil) else {
            throw ShortcutBillingError(message: "附带图片无效，未入账")
        }
        let keepOriginal = override ?? UserDefaults.standard.bool(forKey: "flutter.attachmentKeepOriginal")
        let bytes: Data
        let ext: String
        if keepOriginal {
            bytes = data
            let identifier = CGImageSourceGetType(source) as String?
            ext = identifier.flatMap { UTType($0)?.preferredFilenameExtension } ?? "jpg"
        } else {
            guard let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: 1920,
            ] as CFDictionary),
                  let jpeg = UIImage(cgImage: thumbnail).jpegData(compressionQuality: 0.8) else {
                throw ShortcutBillingError(message: "附件压缩失败，未入账")
            }
            bytes = jpeg
            ext = "jpg"
        }
        guard bytes.count <= 40_000_000 else { throw ShortcutBillingError(message: "附带图片超过 40 MB，未入账") }
        return ["dataBase64": bytes.base64EncodedString(), "extension": ext]
    }
    static func commit(_ submission: [String: Any], attachment: IntentFile? = nil) async throws -> String {
        var submission = submission
        guard submission["confirmed"] as? Bool == true,
              let id = submission["requestId"] as? String else { throw ShortcutBillingError(message: "请先完成草稿确认") }
        if let attachment { submission["attachment"] = try attachmentPayload(attachment) }
        // Only a request ID, no draft/notes/keys, survives interruption.
        UserDefaults.standard.set(id, forKey: "confirmedBillingLastRequestId")
        let response = try decode(await AppIntentsBridge.request(["operation": "commit", "submission": submission]))
        if response["status"] as? String == "committed" { return try encode(response) }
        if response["code"] as? String == "RESULT_UNKNOWN" {
            if let found = try? await call(["operation": "query", "requestId": id]), found["status"] as? String == "committed" { return try encode(found) }
            throw ShortcutBillingError(message: "结果尚未确认。请求 ID：" + id + "。请查看 App 内最近提交凭证并核对账单，勿直接重记。")
        }
        throw ShortcutBillingError(message: (response["message"] as? String ?? "提交未完成") + " 请求 ID：" + id)
    }
    static func resultDialog(_ text: String) throws -> IntentDialog {
        let object = try ConfirmedBilling.decode(text)
        return IntentDialog(stringLiteral: "已入账 " + String(object["count"] as? Int ?? 0) + " 条，合计 " + ConfirmedBilling.money(object["totalAmountMinor"] as? Int ?? 0, digits: object["minorDigits"] as? Int ?? 2) + "。云端尚未确认，请查看 App 同步状态，无需重记。")
    }
    static func money(_ value: Int, digits: Int = 2) -> String {
        let scale = [1, 10, 100, 1000, 10000][digits]
        let sign = value < 0 ? "-" : ""
        let whole = String(abs(value) / scale)
        guard digits > 0 else { return sign + whole }
        let fraction = String(abs(value) % scale)
        return sign + whole + "." + String(repeating: "0", count: digits - fraction.count) + fraction
    }
    static func minor(_ text: String, digits: Int = 2) throws -> Int {
        let pattern = digits == 0 ? "^[0-9]+$" : "^[0-9]+(?:\\.[0-9]{1," + String(digits) + "})?$"
        guard text.count <= 32, text.range(of: pattern, options: .regularExpression) != nil,
              let decimal = Decimal(string: text, locale: Locale(identifier: "en_US_POSIX")) else { throw ShortcutBillingError(message: "请输入大于零、最多两位小数的金额") }
        let number = NSDecimalNumber(decimal: decimal * Decimal([1, 10, 100, 1000, 10000][digits]))
        guard number.compare(0) == .orderedDescending, number.compare(999999999999) != .orderedDescending else { throw ShortcutBillingError(message: "金额超出范围") }
        return number.intValue
    }
    static func label(_ id: Int?, _ options: [[String: Any]]) -> String {
        options.first { $0["id"] as? Int == id }?["name"] as? String ?? "待选择"
    }
    static func summary(_ entry: [String: Any], categories: [[String: Any]], tags: [[String: Any]], digits: Int = 2, type: String = "expense") -> String {
        let tagNames = (entry["tagIds"] as? [Int] ?? []).map { label($0, tags) }.joined(separator: "、")
        return "金额：" + money(entry["amountMinor"] as? Int ?? 0, digits: digits) + (type == "transfer" ? "" : "\n分类：" + label(entry["categoryId"] as? Int, categories)) +
            "\n备注：" + (entry["note"] as? String ?? "") + "\n标签：" + (tagNames.isEmpty ? "无" : tagNames) +
            (type == "expense" ? "\n预算：" + (entry["excludeFromBudget"] as? Bool == true ? "不计入" : "计入") : "")
    }
}

// MARK: - Internal input state for the image/text confirmation flow
// State travels only through the hidden input handoff; no user-built loop is exposed.
// Replaying completed responses restores editing without rerunning AI.
@available(iOS 16.0, *)
struct BillingInputRequest {
    let prompt: String
    let currentValue: String
    let inputType: String
    var payload: [String: Any] { ["prompt": prompt, "currentValue": currentValue, "inputType": inputType] }
}
@available(iOS 16.0, *)
struct BillingInputSuspension: Error { let request: BillingInputRequest }

@available(iOS 16.0, *)
@MainActor
final class BillingStepReplay {
    var events: [[String: String]]
    var cursor = 0
    init(events: [[String: String]]) { self.events = events }

    func recorded(_ kind: String, request: String, produce: () async throws -> String) async throws -> String {
        if cursor < events.count {
            let event = events[cursor]
            guard event["kind"] == kind, event["request"] == request, let response = event["response"] else {
                throw ShortcutBillingError(message: "编辑步骤不一致，已停止且未入账；请重新运行快捷指令")
            }
            cursor += 1
            return response
        }
        guard events.count < 2000 else { throw ShortcutBillingError(message: "编辑步骤过多，未入账") }
        let response = try await produce()
        events.append(["kind": kind, "request": request, "response": response])
        cursor += 1
        return response
    }
}

@available(iOS 16.0, *)
@MainActor
enum BillingStepFlow {
    static func start(_ draft: String, showIncompleteDraft: Bool = false) throws -> String {
        var object = try ConfirmedBilling.decode(draft)
        guard object["status"] as? String == "draft" else { throw ShortcutBillingError(message: "草稿无效") }
        // Fallback time must not change while replaying the same edit session.
        var candidates = object["candidates"] as? [[String: Any]] ?? []
        let now = ISO8601DateFormatter().string(from: Date())
        if candidates.isEmpty { candidates = [["occurredAt": now]] }
        for index in candidates.indices where candidates[index]["occurredAt"] == nil { candidates[index]["occurredAt"] = now }
        object["candidates"] = candidates
        object["editorTime"] = now
        if object["requestId"] == nil { object["requestId"] = UUID().uuidString }
        let state: [String: Any] = ["version": 1, "draft": try ConfirmedBilling.encode(object), "events": [[String: String]](), "showIncompleteDraft": showIncompleteDraft]
        return try ConfirmedBilling.encode(["status": "editing", "state": ConfirmedBilling.encode(state)])
    }

    static func advance(_ envelope: String, response: String?, hasResponse: Bool,
                        choose: @escaping ([String], String) async throws -> String,
                        call: @escaping ([String: Any]) async throws -> [String: Any] = ConfirmedBilling.call) async throws -> String {
        let outer = try ConfirmedBilling.decode(envelope)
        guard ["editing", "input"].contains(outer["status"] as? String ?? ""),
              let encodedState = outer["state"] as? String else { throw ShortcutBillingError(message: "请传入上一次编辑步骤的完整结果") }
        let state = try ConfirmedBilling.decode(encodedState)
        guard state["version"] as? Int == 1, let draft = state["draft"] as? String,
              var events = state["events"] as? [[String: String]], events.count <= 2000 else { throw ShortcutBillingError(message: "编辑状态无效或步骤过多") }
        if outer["status"] as? String == "input" {
            guard hasResponse, let pending = outer["input"] as? [String: Any] else { throw ShortcutBillingError(message: "请把系统询问输入的结果传回，并开启已提供输入") }
            // nil + hasResponse deliberately represents an empty note, not cancellation.
            let value = response ?? ""
            guard value.utf8.count <= 10000 else { throw ShortcutBillingError(message: "输入过长，未入账") }
            events.append(["kind": "input", "request": try ConfirmedBilling.encode(pending), "response": value])
        } else if hasResponse { throw ShortcutBillingError(message: "当前步骤不需要输入") }
        let replay = BillingStepReplay(events: events)
        let editor = ConfirmedBillingEditor(draft: draft, choose: { values, prompt in
            let request = try ConfirmedBilling.encode(["values": values, "prompt": prompt])
            return try await replay.recorded("menu", request: request) { try await choose(values, prompt) }
        }, input: { _ in throw ShortcutBillingError(message: "内部编辑状态缺少输入处理") }, externalInput: { request in
            let key = try ConfirmedBilling.encode(request.payload)
            return try await replay.recorded("input", request: key) { throw BillingInputSuspension(request: request) }
        }, showIncompleteDraft: state["showIncompleteDraft"] as? Bool ?? false, call: { payload in
            // Replay historical options to restore exact menu identities. Final
            // validation and commit always use live references, never cached success.
            let key = try ConfirmedBilling.encode(payload)
            if payload["operation"] as? String == "validate" {
                // Historical *failed* validations must replay identically, or a
                // reference change could skip edits that followed that failure.
                // New/final validation always executes against live references.
                let outcome = try await replay.recorded("validation", request: key) {
                    do { return try ConfirmedBilling.encode(["ok": true, "value": try await call(payload)]) }
                    catch { return try ConfirmedBilling.encode(["ok": false, "message": error.localizedDescription]) }
                }
                let result = try ConfirmedBilling.decode(outcome)
                if result["ok"] as? Bool != true { throw ShortcutBillingError(message: result["message"] as? String ?? "校验失败") }
                return result["value"] as? [String: Any] ?? [:]
            }
            let text = try await replay.recorded("options", request: key) {
                let response = try await call(payload)
                return try ConfirmedBilling.encode(response)
            }
            return try ConfirmedBilling.decode(text)
        })
        do {
            let submission = try await editor.runEditor()
            guard replay.cursor == replay.events.count else { throw ShortcutBillingError(message: "编辑步骤不完整，未入账") }
            return try ConfirmedBilling.encode(["status": "confirmed", "submission": submission])
        } catch let pending as BillingInputSuspension {
            let next: [String: Any] = ["version": 1, "draft": draft, "events": replay.events, "showIncompleteDraft": state["showIncompleteDraft"] as? Bool ?? false]
            return try ConfirmedBilling.encode(["status": "input", "state": try ConfirmedBilling.encode(next), "input": pending.request.payload])
        } catch is CancellationError {
            return try ConfirmedBilling.encode(["status": "cancelled"])
        } catch let error as ShortcutBillingError where error.message == "已取消，未入账" {
            return try ConfirmedBilling.encode(["status": "cancelled"])
        }
    }
}

// MARK: - Internal system-resolved input handoff (no user-built shortcut loop)
// All drafts/transcripts travel as intent parameters. Nothing is stored on disk,
// no global "current bill" exists, and only a confirmed envelope can commit.
@available(iOS 16.0, *)
@MainActor
enum BillingHandoff {
    typealias Result = IntentResultContainer<String, BillingValueInputIntent, Never, IntentDialog>

    enum Outcome {
        case input(String, BillingInputRequest)
        case finished(String)
        case cancelled
    }

    static func advance(_ state: String, response: String? = nil, hasResponse: Bool = false,
                        attachment: IntentFile? = nil,
                        choose: @escaping ([String], String) async throws -> String,
                        call: @escaping ([String: Any]) async throws -> [String: Any] = ConfirmedBilling.call,
                        commit: ([String: Any], IntentFile?) async throws -> String = { try await ConfirmedBilling.commit($0, attachment: $1) }) async throws -> Outcome {
        let next = try await BillingStepFlow.advance(state, response: response, hasResponse: hasResponse, choose: choose, call: call)
        let object = try ConfirmedBilling.decode(next)
        switch object["status"] as? String {
        case "input":
            let request = try inputRequest(next)
            return .input(next, request)
        case "confirmed":
            guard let submission = object["submission"] as? String else { throw ShortcutBillingError(message: "确认结果无效，未入账") }
            return .finished(try await commit(ConfirmedBilling.decode(submission), attachment))
        case "cancelled": return .cancelled
        default: throw ShortcutBillingError(message: "账单编辑状态无效，未入账")
        }
    }

    static func inputRequest(_ state: String) throws -> BillingInputRequest {
        let object = try ConfirmedBilling.decode(state)
        guard object["status"] as? String == "input",
              let input = object["input"] as? [String: Any],
              let prompt = input["prompt"] as? String,
              let current = input["currentValue"] as? String,
              let kind = input["inputType"] as? String, ["text", "number"].contains(kind) else {
            throw ShortcutBillingError(message: "输入请求无效，未入账")
        }
        return BillingInputRequest(prompt: prompt, currentValue: current, inputType: kind)
    }

    static func plain(_ value: String, dialog: IntentDialog) -> Result {
        // Use the iOS 16 generic result overload. Its concrete type stays the
        // same on every branch; nil opensIntent prevents a terminal extra prompt.
        var result: Result = .result(value: value, opensIntent: BillingValueInputIntent(), dialog: dialog)
        result.opensIntent = nil
        return result
    }

    static func result(_ outcome: Outcome, attachment: IntentFile?) throws -> Result {
        switch outcome {
        case let .input(state, request):
            ConfirmedBilling.inputTrace("handoff.system_parameter.requested type=" + request.inputType)
            let next = BillingValueInputIntent(state: state, request: request, attachment: attachment)
            // Do not preassign next.value: that satisfies the required parameter
            // and suppresses the system's input request. Current content is shown
            // separately; dynamic keyboard prefill is NOT promised by this API.
            return .result(value: state, opensIntent: next, dialog: IntentDialog(""))
        case let .finished(saved): return plain(saved, dialog: try ConfirmedBilling.resultDialog(saved))
        case .cancelled: return plain(try ConfirmedBilling.encode(["status": "cancelled"]), dialog: IntentDialog("已取消，未入账"))
        }
    }

    static func start(_ state: String, attachment: IntentFile?,
                      choose: @escaping ([String], String) async throws -> String) async throws -> Result {
        let outcome = try await advance(state, attachment: attachment, choose: choose)
        return try result(outcome, attachment: attachment)
    }
}

@available(iOS 16.0, *)
struct BillingValueInputIntent: AppIntent {
    static var isDiscoverable: Bool = false
    static var title: LocalizedStringResource = "修改账单内容（内部）"
    static var description: LocalizedStringResource = "系统收集输入后继续同一笔账单；金额请用十进制文字填写。不是额外添加到快捷指令的动作。"
    static var openAppWhenRun = false
    @Parameter(title: "本次编辑状态", inputConnectionBehavior: .never) var state: String
    @Parameter(title: "输入项目", inputConnectionBehavior: .never) var field: String
    @Parameter(title: "当前内容", inputConnectionBehavior: .never) var currentValue: String
    @Parameter(title: "新内容", inputOptions: String.IntentInputOptions(multiline: true), requestValueDialog: "请输入修改后的备注、金额或日期", inputConnectionBehavior: .never) var value: String
    @Parameter(title: "附带图片", inputConnectionBehavior: .never) var attachment: IntentFile?
    @Parameter(title: "菜单", inputConnectionBehavior: .never) var choice: String?

    static var parameterSummary: some ParameterSummary {
        Summary("\(\.$field)：\(\.$value)") { \.$currentValue }
    }
    init() {}
    init(state: String, request: BillingInputRequest, attachment: IntentFile?) {
        self.state = state
        self.field = request.prompt
        self.currentValue = request.currentValue
        self.attachment = attachment
        // value deliberately remains unset. The system resolves it before perform.
    }
    @MainActor func perform() async throws -> some IntentResult & ReturnsValue<String> & ProvidesDialog & OpensIntent {
        _ = try BillingHandoff.inputRequest(state)
        ConfirmedBilling.inputTrace("handoff.system_parameter.received")
        let outcome = try await BillingHandoff.advance(state, response: value, hasResponse: true, attachment: attachment, choose: { values, prompt in
            try await $choice.requestDisambiguation(among: values, dialog: IntentDialog(stringLiteral: prompt))
        })
        return try BillingHandoff.result(outcome, attachment: attachment)
    }
}

@available(iOS 16.0, *)
@MainActor
final class ConfirmedBillingEditor {
    let draft: String
    let choose: ([String], String) async throws -> String
    let input: (String) async throws -> String
    let call: ([String: Any]) async throws -> [String: Any]
    let externalInput: ((BillingInputRequest) async throws -> String)?
    let showIncompleteDraft: Bool

    init(draft: String,
         choose: @escaping ([String], String) async throws -> String,
         input: @escaping (String) async throws -> String,
         externalInput: ((BillingInputRequest) async throws -> String)? = nil,
         showIncompleteDraft: Bool = false,
         call: @escaping ([String: Any]) async throws -> [String: Any] = ConfirmedBilling.call) {
        self.draft = draft; self.choose = choose; self.input = input; self.call = call
        self.externalInput = externalInput
        self.showIncompleteDraft = showIncompleteDraft
    }

    private func ask(_ prompt: String, current: String = "", kind: String = "text") async throws -> String {
        if let externalInput { return try await externalInput(BillingInputRequest(prompt: prompt, currentValue: current, inputType: kind)) }
        return try await input(prompt)
    }
    @MainActor private func pick(_ values: [[String: Any]], _ prompt: String) async throws -> Int {
        guard !values.isEmpty else { throw ShortcutBillingError(message: "没有可选项，请先在 App 配置") }
        let labels = values.enumerated().map { String($0.offset + 1) + ". " + ($0.element["name"] as? String ?? "") }
        let selected = try await choose(labels, prompt)
        guard let index = labels.firstIndex(of: selected), let id = values[index]["id"] as? Int else { throw ShortcutBillingError(message: "选项已失效") }
        return id
    }
    private func fields(_ actions: [String], title: String, values: [String: String]) async throws -> String {
        let labels = actions.map { action in values[action].map { action + "：" + $0 } ?? action }
        ConfirmedBilling.inputTrace("editor.menu.requested")
        let selected = try await choose(labels, title)
        ConfirmedBilling.inputTrace("editor.menu.returned")
        return labels.firstIndex(of: selected).map { actions[$0] } ?? selected
    }
    @MainActor private func edit(_ initial: [String: Any], categories: [[String: Any]], tags: [[String: Any]], digits: Int, type: String, maximum: Int? = nil) async throws -> [String: Any]? {
        var entry = initial
        while true {
            let fields = ["完成此笔", "金额"] + (type == "transfer" ? [] : ["分类"]) + ["备注", "标签"] + (type == "expense" ? ["预算标记"] : []) + ["取消本次字段修改"]
            let selected = try await self.fields(fields, title: "编辑账单明细", values: [
                "金额": ConfirmedBilling.money(entry["amountMinor"] as? Int ?? 0, digits: digits),
                "分类": entry["categoryId"] == nil ? "未分类" : ConfirmedBilling.label(entry["categoryId"] as? Int, categories),
                "备注": entry["note"] as? String ?? "",
                "标签": (entry["tagIds"] as? [Int] ?? []).map { ConfirmedBilling.label($0, tags) }.joined(separator: "、"),
                "预算标记": entry["excludeFromBudget"] as? Bool == true ? "不计入预算" : "计入预算"
            ])
            switch selected {
            case "完成此笔":
                if let maximum, (entry["amountMinor"] as? Int ?? 0) > maximum {
                    _ = try await choose(["返回修改"], "此笔超过剩余金额 " + ConfirmedBilling.money(maximum, digits: digits) + "，请修改金额")
                    continue
                }
                guard (entry["amountMinor"] as? Int ?? 0) > 0, (type == "transfer" || entry["categoryId"] == nil || categories.contains(where: { $0["id"] as? Int == entry["categoryId"] as? Int })) else { _ = try await choose(["返回修改"], "请输入正金额；已选分类必须有效"); continue }
                return entry
            case "金额":
                let value: String
                do { value = try await ask("修改此笔金额", current: ConfirmedBilling.money(entry["amountMinor"] as? Int ?? 0, digits: digits), kind: "number") }
                catch let pending as BillingInputSuspension { throw pending }
                catch is CancellationError { continue }
                catch { _ = try await choose(["返回账单"], error.localizedDescription); continue }
                if let amount = try? ConfirmedBilling.minor(value, digits: digits), (maximum.map({ amount <= $0 }) ?? true) { entry["amountMinor"] = amount }
                else { _ = try await choose(["返回修改"], "金额无效：须为正数、符合账本精度，且不能超过可分配金额") }
            case "分类": entry["categoryId"] = try await pick(categories, "选择分类")
            case "备注":
                ConfirmedBilling.inputTrace("detail.note.selected")
                let old = entry["note"] as? String ?? ""
                do {
                    entry["note"] = ConfirmedBilling.updatedNote(old, value: try await ask("修改备注（可留空）；原备注：" + old, current: old))
                    ConfirmedBilling.inputTrace("detail.note.applied")
                } catch let pending as BillingInputSuspension { throw pending }
                catch is CancellationError { ConfirmedBilling.inputTrace("detail.note.cancelled_returning"); continue }
                catch {
                    ConfirmedBilling.inputTrace("detail.note.error_returning")
                    _ = try await choose(["返回账单"], error.localizedDescription)
                }
            case "标签": entry["tagIds"] = ConfirmedBilling.nextTag(entry["tagIds"] as? [Int] ?? [], tags: tags)
            case "预算标记": entry["excludeFromBudget"] = !(entry["excludeFromBudget"] as? Bool ?? false)
            default: return nil
            }
        }
    }

    @MainActor func runEditor() async throws -> String {
        let source = try ConfirmedBilling.decode(draft)
        guard source["status"] as? String == "draft", var ledgerId = source["ledgerId"] as? Int else { throw ShortcutBillingError(message: "请先生成草稿") }
        // Fresh references after recognition; no bridge call stays open while editing.
        var options = try await call(["operation": "options", "ledgerId": ledgerId])
        var digits = options["minorDigits"] as? Int ?? 2
        var currency = options["currency"] as? String ?? "CNY"
        if let originalCurrency = source["currency"] as? String, originalCurrency != currency {
            throw ShortcutBillingError(message: "账本币种在识别后发生变化，请重新生成草稿")
        }
        var categories = options["categories"] as? [[String: Any]] ?? []
        var accounts = options["accounts"] as? [[String: Any]] ?? []
        var tags = options["tags"] as? [[String: Any]] ?? []
        let defaults = options["defaults"] as? [String: Any] ?? [:]
        let candidates = source["candidates"] as? [[String: Any]] ?? []
        var candidate: [String: Any]
        if candidates.count > 1 {
            let labels = candidates.enumerated().map { String($0.offset + 1) + ". " + ConfirmedBilling.money($0.element["amountMinor"] as? Int ?? 0, digits: digits) + " " + ($0.element["merchant"] as? String ?? "") }
            let selected = try await choose(labels + ["人工填写", "取消"], "识别到多个候选，请只选择本次付款")
            if selected == "取消" { throw ShortcutBillingError(message: "已取消，未入账") }
            candidate = labels.firstIndex(of: selected).map { candidates[$0] } ?? [:]
        } else { candidate = candidates.first ?? [:] }
        var type = candidate["type"] as? String ?? "expense"
        if !["expense", "income", "transfer"].contains(type) { type = "expense" }
        options = try await call(["operation": "options", "ledgerId": ledgerId, "type": type])
        categories = options["categories"] as? [[String: Any]] ?? []
        if candidate["blocked"] as? Bool == true {
            let action = try await choose(["核对后人工填写", "取消"], "识别币种与账本冲突，请核对后人工填写，不能直接提交")
            if action == "取消" { throw ShortcutBillingError(message: "已取消，未入账") }
            candidate = [:]
        }
        var total = candidate["amountMinor"] as? Int ?? 0
        // Text drafts must reach review before requesting any missing fields.
        if !showIncompleteDraft {
            while total <= 0 {
                let value = try await ask("输入本次金额（" + currency + "）", kind: "number")
                if let amount = try? ConfirmedBilling.minor(value, digits: digits) { total = amount }
                else { _ = try await choose(["重新填写"], "金额无效，请填写正金额并遵守账本小数位数") }
            }
        }
        // Missing/ambiguous recognition must ask, not inherit a default account.
        var accountId = candidate["accountId"] as? Int
        if !accounts.contains(where: { $0["id"] as? Int == accountId }) {
            accountId = nil
            if !showIncompleteDraft {
                accountId = try await pick(accounts, type == "income" ? "选择收款账户" : "选择付款或转出账户")
            }
        }
        var toAccountId = candidate["toAccountId"] as? Int
        if type == "transfer" && !accounts.contains(where: { $0["id"] as? Int == toAccountId && toAccountId != accountId }) {
            toAccountId = nil
            if !showIncompleteDraft { toAccountId = try await pick(accounts.filter { $0["id"] as? Int != accountId }, "选择转入账户") }
        }
        var time = candidate["occurredAt"] as? String ?? source["editorTime"] as? String ?? ISO8601DateFormatter().string(from: Date())
        var entries: [[String: Any]] = [["amountMinor": total, "note": candidate["note"] as? String ?? "",
            "tagIds": Array((candidate["tagIds"] as? [Int] ?? defaults["tagIds"] as? [Int] ?? []).prefix(1)),
            "excludeFromBudget": type == "expense" && (candidate["excludeFromBudget"] as? Bool ?? defaults["excludeFromBudget"] as? Bool ?? false)]]
        if let categoryId = candidate["categoryId"] as? Int { entries[0]["categoryId"] = categoryId }
        var didSplit = false
        var splitTemplate = entries[0]
        func typeName(_ value: String) -> String { value == "income" ? "收入" : value == "transfer" ? "转账" : "支出" }
        while true {
            let used = entries.reduce(0) { $0 + ($1["amountMinor"] as? Int ?? 0) }
            let detail = entries.enumerated().map { "第 " + String($0.offset + 1) + " 笔\n" + ConfirmedBilling.summary($0.element, categories: categories, tags: tags, digits: digits, type: type) }.joined(separator: "\n")
            let excess = used > total ? "（超额 " + ConfirmedBilling.money(used - total, digits: digits) + "，请修改）" : ""
            let ledgerName = ConfirmedBilling.label(ledgerId, options["ledgers"] as? [[String: Any]] ?? [])
            let accountSummary = ConfirmedBilling.label(accountId, accounts) + (type == "transfer" ? " → " + ConfirmedBilling.label(toAccountId, accounts) : "")
            let summary = typeName(type) + " " + ConfirmedBilling.money(total, digits: digits) + " " + currency + " · 账本 " + ledgerName + " · 账户 " + accountSummary + "\n时间：" + ConfirmedBilling.displayTime(time) + "\n剩余：" + ConfirmedBilling.money(max(0, total - used), digits: digits) + excess + "\n" + detail
            let single = entries.count == 1 && !didSplit
            let entry = entries.first ?? [:]
            let tagNames = (entry["tagIds"] as? [Int] ?? []).map { ConfirmedBilling.label($0, tags) }.joined(separator: "、")
            let directFields = single ? ["金额"] + (type == "transfer" ? [] : ["分类"]) + ["账户", "时间", "备注", "标签"] + (type == "expense" ? ["不计预算"] : []) : ["编辑明细", "删除明细", "修改原付款金额", "记账账户", "日期时间"]
            let actions = directFields + (type == "transfer" ? ["转入账户"] : []) +
                (type == "expense" ? ["拆分或新增明细"] : []) +
                ["账本", "收支类型", "确认提交", "取消提交", "刷新有效选项"]
            let menuTitle = single ? "确认" + typeName(type) + "信息" : summary
            let selected = try await fields(actions, title: menuTitle, values: [
                "金额": total > 0 ? ConfirmedBilling.money(total, digits: digits) : "待填写", "分类": entry["categoryId"] == nil ? "未分类" : ConfirmedBilling.label(entry["categoryId"] as? Int, categories),
                "账户": ConfirmedBilling.label(accountId, accounts), "转入账户": ConfirmedBilling.label(toAccountId, accounts),
                "时间": ConfirmedBilling.displayTime(time), "备注": entry["note"] as? String ?? "", "标签": tagNames.isEmpty ? "无" : tagNames,
                "不计预算": entry["excludeFromBudget"] as? Bool == true ? "不计入预算" : "计入预算",
                "账本": ledgerName, "收支类型": typeName(type)
            ])
            let action = ["金额": "修改原付款金额", "账户": "记账账户", "时间": "日期时间", "取消提交": "取消整次记账"][selected] ?? selected
            switch action {
            case "分类": entries[0]["categoryId"] = try await pick(categories, "选择分类")
            case "备注":
                ConfirmedBilling.inputTrace("bill.note.selected")
                let old = entries[0]["note"] as? String ?? ""
                do {
                    entries[0]["note"] = ConfirmedBilling.updatedNote(old, value: try await ask("修改备注（可留空）；原备注：" + old, current: old))
                    ConfirmedBilling.inputTrace("bill.note.applied")
                } catch let pending as BillingInputSuspension { throw pending }
                catch is CancellationError { ConfirmedBilling.inputTrace("bill.note.cancelled_returning"); continue }
                catch {
                    ConfirmedBilling.inputTrace("bill.note.error_returning")
                    _ = try await choose(["返回账单"], error.localizedDescription)
                }
            case "标签": entries[0]["tagIds"] = ConfirmedBilling.nextTag(entries[0]["tagIds"] as? [Int] ?? [], tags: tags)
            case "不计预算": entries[0]["excludeFromBudget"] = !(entries[0]["excludeFromBudget"] as? Bool ?? false)
            case "取消整次记账": throw ShortcutBillingError(message: "已取消，未入账")
            case "记账账户":
                accountId = try await pick(accounts, type == "income" ? "选择收款账户" : "选择付款或转出账户")
                if toAccountId == accountId { toAccountId = nil }
            case "转入账户": toAccountId = try await pick(accounts.filter { $0["id"] as? Int != accountId }, "选择转入账户")
            case "刷新有效选项":
                options = try await call(["operation": "options", "ledgerId": ledgerId, "type": type])
                categories = options["categories"] as? [[String: Any]] ?? []
                accounts = options["accounts"] as? [[String: Any]] ?? []
                tags = options["tags"] as? [[String: Any]] ?? []
            case "账本":
                let selected = try await pick(options["ledgers"] as? [[String: Any]] ?? [], "切换账本")
                if selected == ledgerId { continue }
                let fresh = try await call(["operation": "options", "ledgerId": selected, "type": type])
                let newCurrency = fresh["currency"] as? String ?? "CNY"
                if newCurrency != currency {
                    if try await choose(["切换并重新填写金额", "返回"], "新账本币种不同，不自动换算；切换将清空拆分金额") == "返回" { continue }
                    total = 0
                    while total <= 0 {
                        let value = try await ask("请输入新账本的原金额（" + newCurrency + "）", kind: "number")
                        total = (try? ConfirmedBilling.minor(value, digits: fresh["minorDigits"] as? Int ?? 2)) ?? 0
                    }
                    var entry = entries.first ?? [:]
                    entry["amountMinor"] = total
                    entries = [entry]; didSplit = false
                }
                ledgerId = selected; options = fresh; currency = newCurrency
                digits = fresh["minorDigits"] as? Int ?? 2
                categories = fresh["categories"] as? [[String: Any]] ?? []
                accounts = fresh["accounts"] as? [[String: Any]] ?? []
                tags = fresh["tags"] as? [[String: Any]] ?? []
                if !accounts.contains(where: { $0["id"] as? Int == accountId }) {
                    accountId = nil
                    accountId = try await pick(accounts, "选择记账账户")
                }
                if !accounts.contains(where: { $0["id"] as? Int == toAccountId }) { toAccountId = nil }
            case "收支类型":
                let value = try await choose(["支出", "收入", "转账", "返回"], "修改类型后重新校验分类和账户；收入与转账只支持单笔")
                if value == "返回" { continue }
                let next = value == "收入" ? "income" : value == "转账" ? "transfer" : "expense"
                if next == type { continue }
                if entries.count > 1 {
                    if try await choose(["合并草稿为单笔", "返回"], "更改类型会丢弃拆分草稿，仅保留第一笔备注和标签") == "返回" { continue }
                }
                type = next
                options = try await call(["operation": "options", "ledgerId": ledgerId, "type": type])
                categories = options["categories"] as? [[String: Any]] ?? []
                var entry = entries.first ?? [:]
                entry["amountMinor"] = total; entry.removeValue(forKey: "categoryId")
                entry["excludeFromBudget"] = false
                entries = [entry]; didSplit = false; toAccountId = nil
                if type == "transfer" { toAccountId = try await pick(accounts.filter { $0["id"] as? Int != accountId }, "选择转入账户") }
            case "日期时间":
                let value = try await ask("输入完整日期时间，如 2026-11-05T18:30:00+08:00", current: time, kind: "text")
                let formatter = ISO8601DateFormatter()
                formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
                if ISO8601DateFormatter().date(from: value) != nil || formatter.date(from: value) != nil { time = value }
                else { _ = try await choose(["返回修改"], "日期时间格式无效，请输入带时区的完整日期时间") }
            case "修改原付款金额":
                let value: String
                do { value = try await ask("输入原付款总额", current: ConfirmedBilling.money(total, digits: digits), kind: "number") }
                catch let pending as BillingInputSuspension { throw pending }
                catch is CancellationError { continue }
                catch { _ = try await choose(["返回账单"], error.localizedDescription); continue }
                if let amount = try? ConfirmedBilling.minor(value, digits: digits) {
                    total = amount
                    if !didSplit && entries.count == 1 { entries[0]["amountMinor"] = amount }
                } else { _ = try await choose(["返回修改"], "请输入有效正金额") }
            case "拆分或新增明细":
                if didSplit && entries.count >= 100 {
                    _ = try await choose(["返回账单"], "最多支持 100 笔明细，请先删除已有明细，再新增")
                    continue
                }
                let remaining = didSplit ? total - used : total
                if remaining <= 0 {
                    guard didSplit, !entries.isEmpty, total > 0 else {
                        _ = try await choose(["返回账单"], "请先填写有效的原付款金额，再拆分明细")
                        continue
                    }
                    // A full allocation isn't an inert Add button. Go straight
                    // to existing detail selection without another confirmation.
                    let labels = entries.enumerated().map { "第 " + String($0.offset + 1) + " 笔 " + ConfirmedBilling.money($0.element["amountMinor"] as? Int ?? 0, digits: digits) }
                    let prompt = remaining == 0
                        ? "金额已分配完，请选择一笔明细调小金额，腾出余额后可继续新增"
                        : "明细已超额 " + ConfirmedBilling.money(-remaining, digits: digits) + "，请选择一笔明细调整金额"
                    let selected = try await choose(labels + ["返回"], prompt)
                    guard let index = labels.firstIndex(of: selected) else { continue }
                    let maximum = total - used + (entries[index]["amountMinor"] as? Int ?? 0)
                    guard maximum > 0 else {
                        _ = try await choose(["返回账单"], "其他明细已用完或超过总额，请先删除其他明细或修改原付款金额")
                        continue
                    }
                    do {
                        if let entry = try await edit(entries[index], categories: categories, tags: tags, digits: digits, type: type, maximum: maximum) { entries[index] = entry }
                    } catch let pending as BillingInputSuspension { throw pending }
                    catch is CancellationError { continue }
                    continue
                }
                // Preserve edited values, not the original AI candidate.
                if !didSplit, let first = entries.first { splitTemplate = first }
                var initial = splitTemplate
                initial["amountMinor"] = remaining
                do {
                    guard let entry = try await edit(initial, categories: categories, tags: tags, digits: digits, type: type, maximum: remaining) else { continue }
                    if !didSplit { entries = []; didSplit = true }
                    entries.append(entry)
                } catch let pending as BillingInputSuspension { throw pending }
                catch is CancellationError { continue }
            case "编辑明细", "删除明细":
                guard !entries.isEmpty else { continue }
                let labels = entries.enumerated().map { "第 " + String($0.offset + 1) + " 笔 " + ConfirmedBilling.money($0.element["amountMinor"] as? Int ?? 0, digits: digits) }
                let selected = try await choose(labels + ["返回"], "选择明细")
                guard let index = labels.firstIndex(of: selected) else { continue }
                if action == "删除明细" { entries.remove(at: index); didSplit = true }
                else {
                    do {
                        if let entry = try await edit(entries[index], categories: categories, tags: tags, digits: digits, type: type, maximum: total - used + (entries[index]["amountMinor"] as? Int ?? 0)) { entries[index] = entry }
                    } catch let pending as BillingInputSuspension { throw pending }
                    catch is CancellationError { continue }
                }
            case "确认提交":
                guard !entries.isEmpty, used == total, entries.allSatisfy({ entry in
                    (entry["amountMinor"] as? Int ?? 0) > 0 && (type == "transfer" || entry["categoryId"] == nil || categories.contains { $0["id"] as? Int == entry["categoryId"] as? Int })
                }) else { _ = try await choose(["返回修改"], "金额尚未分配完、超额或已选分类失效，不能提交"); continue }
                guard let confirmedAccountId = accountId, accounts.contains(where: { $0["id"] as? Int == confirmedAccountId }) else {
                    accountId = try await pick(accounts, type == "income" ? "选择收款账户" : "选择付款或转出账户")
                    continue
                }
                if type == "transfer" && (toAccountId == nil || toAccountId == accountId) {
                    toAccountId = try await pick(accounts.filter { $0["id"] as? Int != accountId }, "选择不同的转入账户"); continue
                }
                var submission: [String: Any] = ["schemaVersion": 1, "confirmed": true, "requestId": source["requestId"] as? String ?? UUID().uuidString,
                    "ledgerId": ledgerId, "accountId": confirmedAccountId, "currency": currency, "type": type, "occurredAt": time,
                    "originalAmountMinor": total, "entries": entries]
                if type == "transfer" { submission["toAccountId"] = toAccountId }
                do { _ = try await call(["operation": "validate", "submission": submission]) }
                catch { _ = try await choose(["返回修改"], error.localizedDescription); continue }
                return try ConfirmedBilling.encode(submission)
            default: break
            }
        }
    }
}


@available(iOS 16.0, *)
struct BillingLedger: AppEntity {
    static var typeDisplayRepresentation: TypeDisplayRepresentation = "账本"
    static var defaultQuery = BillingLedgerQuery()
    var id: Int
    var name: String
    var displayRepresentation: DisplayRepresentation { DisplayRepresentation(title: "\(name)") }
}
@available(iOS 16.0, *)
struct BillingLedgerQuery: EntityStringQuery {
    @MainActor func suggestedEntities() async throws -> [BillingLedger] {
        let options = try await ConfirmedBilling.call(["operation": "options"])
        var rows = options["ledgers"] as? [[String: Any]] ?? []

        return rows.compactMap { row in
            guard let id = row["id"] as? Int, let name = row["name"] as? String else { return nil }
            return BillingLedger(id: id, name: name)
        }
    }
    @MainActor func entities(for identifiers: [Int]) async throws -> [BillingLedger] {
        try await suggestedEntities().filter { identifiers.contains($0.id) }
    }
    @MainActor func entities(matching string: String) async throws -> [BillingLedger] {
        try await suggestedEntities().filter { $0.name.localizedCaseInsensitiveContains(string) }
    }
}


@available(iOS 16.0, *)
struct BillingTag: AppEntity {
    static var typeDisplayRepresentation: TypeDisplayRepresentation = "标签"
    static var defaultQuery = BillingTagQuery()
    var id: Int
    var name: String
    var displayRepresentation: DisplayRepresentation { DisplayRepresentation(title: "\(name)") }
}
@available(iOS 16.0, *)
struct BillingTagQuery: EntityStringQuery {
    @MainActor func suggestedEntities() async throws -> [BillingTag] {
        let options = try await ConfirmedBilling.call(["operation": "options"])
        var rows = options["tags"] as? [[String: Any]] ?? []

        return rows.compactMap { row in
            guard let id = row["id"] as? Int, let name = row["name"] as? String else { return nil }
            return BillingTag(id: id, name: name)
        }
    }
    @MainActor func entities(for identifiers: [Int]) async throws -> [BillingTag] {
        try await suggestedEntities().filter { identifiers.contains($0.id) }
    }
    @MainActor func entities(matching string: String) async throws -> [BillingTag] {
        try await suggestedEntities().filter { $0.name.localizedCaseInsensitiveContains(string) }
    }
}


// Both public actions own their prompt parameters and share the same editor.
// They do not invoke another hidden intent's perform() or ask for JSON.
@available(iOS 16.0, *)
@MainActor
enum RecognitionBillingFlow {
    static func configuration(ledger: BillingLedger?, tags: [BillingTag]?, clearTags: Bool, excluded: Bool?) -> [String: Any] {
        var config: [String: Any] = [:]
        if let ledger { config["ledgerId"] = ledger.id }
        if clearTags { config["tagIds"] = [Int]() }
        else if let tags { config["tagIds"] = Array(Set(tags.map { $0.id })).sorted() }
        if let excluded { config["excludeFromBudget"] = excluded }
        return config
    }

    static func run(image: IntentFile? = nil, text: String? = nil,
                    configuration: [String: Any],
                    attachment: IntentFile? = nil,
                    independentInput: Bool = false,
                    showIncompleteDraft: Bool = false,
                    choose: @escaping ([String], String) async throws -> String,
                    input: @escaping (String) async throws -> String,
                    call: @escaping ([String: Any]) async throws -> [String: Any] = ConfirmedBilling.call,
                    commit: ([String: Any], IntentFile?) async throws -> String = { try await ConfirmedBilling.commit($0, attachment: $1) }) async throws -> String {
        guard (image != nil) != (text != nil) else {
            throw ShortcutBillingError(message: "请选择图片记账或文字记账，并连接对应输入")
        }
        // Resolve the ledger before sending any bill data. No first-ledger fallback.
        let options = try await call(configuration.merging(["operation": "options"]) { _, value in value })
        guard let ledgerId = options["ledgerId"] as? Int, let currency = options["currency"] as? String else {
            throw ShortcutBillingError(message: "当前账本信息无效，未入账，请在 App 中检查账本")
        }
        var config = configuration
        config["ledgerId"] = ledgerId
        var draft: [String: Any]
        do {
            if let image {
                draft = try await ConfirmedBilling.recognizeImage(image, ocr: false, configuration: ConfirmedBilling.encode(config))
            } else {
                var payload = config
                payload["operation"] = "recognize"
                payload["mode"] = "text"
                payload["timeZoneOffsetSeconds"] = TimeZone.current.secondsFromGMT()
                payload["text"] = text ?? ""
                draft = try await call(payload)
            }
        } catch is CancellationError { throw CancellationError() }
        catch {
            let detail = (error as? ShortcutBillingError)?.message ?? "请检查输入和 App 内 AI 配置"
            if try await choose(["人工填写", "取消"], "识别未完成，未入账。" + detail) == "取消" { throw error }
            let defaults = options["defaults"] as? [String: Any] ?? [:]
            var candidate: [String: Any] = ["type": "expense", "note": "",
                "tagIds": config["tagIds"] ?? defaults["tagIds"] ?? [Int](),
                "excludeFromBudget": config["excludeFromBudget"] ?? defaults["excludeFromBudget"] ?? false]
            candidate["requiresAccountSelection"] = true
            draft = ["status": "draft", "requestId": UUID().uuidString,
                "ledgerId": ledgerId, "currency": currency, "candidates": [candidate]]
        }
        if independentInput { return try BillingStepFlow.start(ConfirmedBilling.encode(draft), showIncompleteDraft: showIncompleteDraft) }
        let editor = ConfirmedBillingEditor(draft: try ConfirmedBilling.encode(draft), choose: choose, input: input, showIncompleteDraft: showIncompleteDraft, call: call)
        // Cancellation exits before commit. Existing atomic/idempotent store is reused.
        let submission = try await editor.runEditor()
        return try await commit(ConfirmedBilling.decode(submission), attachment)
    }
}

@available(iOS 16.0, *)
struct ImageConfirmBillingIntent: AppIntent {
    static var isDiscoverable: Bool = false
    static var title: LocalizedStringResource = "图片记账"
    static var description: LocalizedStringResource = "将图片交给 App 内 AI 判断收支、识别金额和账户；按分类规则预填，核对、编辑或拆分后一次确认入账。"
    static var openAppWhenRun = false
    @Parameter(title: "图片") var image: IntentFile
    @Parameter(title: "账本（留空使用当前账本）") var ledger: BillingLedger?
    @Parameter(title: "标签（留空跟随 App）") var tags: [BillingTag]?
    @Parameter(title: "清空标签", default: false) var clearTags: Bool
    @Parameter(title: "不计预算（仅支出，留空跟随 App）") var excluded: Bool?
    @Parameter(title: "附带图片", inputConnectionBehavior: .never) var attachment: IntentFile?
    @Parameter(title: "菜单", inputConnectionBehavior: .never) var choice: String?
    static var parameterSummary: some ParameterSummary {
        Summary("识别\(\.$image)并确认记账") { \.$ledger; \.$tags; \.$clearTags; \.$excluded; \.$attachment }
    }
    @MainActor func perform() async throws -> some IntentResult & ReturnsValue<String> & ProvidesDialog & OpensIntent {
        let config = RecognitionBillingFlow.configuration(ledger: ledger, tags: tags, clearTags: clearTags, excluded: excluded)
        let saved = try await RecognitionBillingFlow.run(image: image, configuration: config, attachment: attachment, independentInput: true, choose: { values, prompt in
            try await $choice.requestDisambiguation(among: values, dialog: IntentDialog(stringLiteral: prompt))
        }, input: { _ in throw ShortcutBillingError(message: "普通入口必须交给独立系统输入") })
        return try await BillingHandoff.start(saved, attachment: attachment, choose: { values, prompt in
            try await $choice.requestDisambiguation(among: values, dialog: IntentDialog(stringLiteral: prompt))
        })
    }
}


// The text entry always reviews a draft before committing. There is no public
// draft-only switch, external step action or user-built confirmation loop.
@available(iOS 16.0, *)
@MainActor
enum TextBillingEntry {
    static func source(_ text: String?) -> String {
        (text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func run(text: String, configuration: [String: Any],
                    attachment: IntentFile? = nil, independentInput: Bool = false,
                    choose: @escaping ([String], String) async throws -> String,
                    input: @escaping (String) async throws -> String,
                    call: @escaping ([String: Any]) async throws -> [String: Any] = ConfirmedBilling.call,
                    commit: ([String: Any], IntentFile?) async throws -> String = { try await ConfirmedBilling.commit($0, attachment: $1) }) async throws -> String {
        let text = source(text)
        guard !text.isEmpty else { throw ShortcutBillingError(message: "没有收到记账文字，未入账") }
        // Keep options failures visible both before recognition and when the
        // editor refreshes references. Retrying options must never repeat AI.
        let visibleCall: ([String: Any]) async throws -> [String: Any] = { payload in
            while true {
                do { return try await call(payload) }
                catch is CancellationError { throw CancellationError() }
                catch {
                    guard payload["operation"] as? String == "options" else { throw error }
                    let action = try await choose(["重试", "取消"], "文字记账无法读取账本选项，未入账。请检查当前账本及 App 初始化状态。" + error.localizedDescription)
                    if action != "重试" { throw CancellationError() }
                }
            }
        }
        return try await RecognitionBillingFlow.run(text: text, configuration: configuration,
            attachment: attachment, independentInput: independentInput, showIncompleteDraft: true,
            choose: choose, input: input, call: visibleCall, commit: commit)
    }
}

@available(iOS 16.0, *)
struct TextConfirmBillingIntent: AppIntent {
    static var isDiscoverable: Bool = false
    static var title: LocalizedStringResource = "文字记账"
    static var description: LocalizedStringResource = "接收文字或截图 OCR 文本，调用 App 内文字 AI 自动识别，弹窗编辑和拆分，确认后直接入账。"
    static var openAppWhenRun = false
    @Parameter(title: "文字", requestValueDialog: "请输入记账文字，或连接截图提取的文本") var text: String?
    @Parameter(title: "账本（留空使用当前账本）") var ledger: BillingLedger?
    @Parameter(title: "标签（留空跟随 App）") var tags: [BillingTag]?
    @Parameter(title: "清空标签", default: false) var clearTags: Bool
    @Parameter(title: "不计预算（仅支出，留空跟随 App）") var excluded: Bool?
    @Parameter(title: "附带图片", inputConnectionBehavior: .never) var attachment: IntentFile?
    @Parameter(title: "菜单", inputConnectionBehavior: .never) var choice: String?
    static var parameterSummary: some ParameterSummary {
        Summary("识别\(\.$text)并确认记账") { \.$ledger; \.$tags; \.$clearTags; \.$excluded; \.$attachment }
    }
    @MainActor func perform() async throws -> some IntentResult & ReturnsValue<String> & ProvidesDialog & OpensIntent {
        let source = TextBillingEntry.source(text)
        guard !source.isEmpty else {
            throw $text.needsValueError("请输入记账文字，或连接截图提取的文本")
        }
        let config = RecognitionBillingFlow.configuration(ledger: ledger, tags: tags, clearTags: clearTags, excluded: excluded)
        let saved = try await TextBillingEntry.run(text: source, configuration: config, attachment: attachment, independentInput: true, choose: { values, prompt in
            try await $choice.requestDisambiguation(among: values, dialog: IntentDialog(stringLiteral: prompt))
        }, input: { _ in throw ShortcutBillingError(message: "普通入口必须交给独立系统输入") })
        return try await BillingHandoff.start(saved, attachment: attachment, choose: { values, prompt in
            try await $choice.requestDisambiguation(among: values, dialog: IntentDialog(stringLiteral: prompt))
        })
    }
}


// MARK: - Variable billing: two user-facing actions, no recognition or step template
@available(iOS 16.0, *)
struct BillingAccount: AppEntity {
    static var typeDisplayRepresentation: TypeDisplayRepresentation = "账户"
    static var defaultQuery = BillingAccountQuery()
    var id: Int
    var name: String
    var displayRepresentation: DisplayRepresentation { DisplayRepresentation(title: "\(name)") }
}
@available(iOS 16.0, *)
struct BillingAccountQuery: EntityStringQuery {
    @MainActor func suggestedEntities() async throws -> [BillingAccount] {
        let options = try await ConfirmedBilling.call(["operation": "options"])
        var rows = options["accounts"] as? [[String: Any]] ?? []
        for ledger in options["ledgers"] as? [[String: Any]] ?? [] {
            guard let id = ledger["id"] as? Int, id != options["ledgerId"] as? Int else { continue }
            let other = try await ConfirmedBilling.call(["operation": "options", "ledgerId": id])
            for row in other["accounts"] as? [[String: Any]] ?? [] where !rows.contains(where: { $0["id"] as? Int == row["id"] as? Int }) { rows.append(row) }
        }
        return rows.compactMap { row in
            guard let id = row["id"] as? Int, let name = row["name"] as? String else { return nil }
            return BillingAccount(id: id, name: name)
        }
    }
    @MainActor func entities(for identifiers: [Int]) async throws -> [BillingAccount] {
        try await suggestedEntities().filter { identifiers.contains($0.id) }
    }
    @MainActor func entities(matching string: String) async throws -> [BillingAccount] {
        try await suggestedEntities().filter { $0.name.localizedCaseInsensitiveContains(string) }
    }
}

/// Run-local value. No global current bill, receipt or persistent draft is created here.
@available(iOS 16.0, *)
struct VariableBillingDraft: TransientAppEntity {
    static var typeDisplayRepresentation: TypeDisplayRepresentation = "待确认账单"
    @Property(title: "账单内容") var payload: String
    @Property(title: "支付截屏") var screenshot: IntentFile?
    var displayRepresentation: DisplayRepresentation { DisplayRepresentation(title: "待确认账单") }
    init() {}
    init(payload: String, screenshot: IntentFile?) {
        self.payload = payload
        self.screenshot = screenshot
    }
}

@available(iOS 16.0, *)
struct PrepareVariableBillingIntent: AppIntent {
    static var isDiscoverable = true
    static var title: LocalizedStringResource = "准备账单"
    static var description: LocalizedStringResource = "接收已准备的变量，生成待确认账单，不调用 AI、不入账。下一步连接确认并记账。"
    static var openAppWhenRun = false
    @Parameter(title: "金额", inputConnectionBehavior: .never) var amount: String?
    @Parameter(title: "类型", inputConnectionBehavior: .never) var type: String?
    @Parameter(title: "账本", inputConnectionBehavior: .never) var ledger: BillingLedger?
    @Parameter(title: "分类", inputConnectionBehavior: .never) var category: String?
    @Parameter(title: "标签", inputConnectionBehavior: .never) var tag: String?
    @Parameter(title: "账户", inputConnectionBehavior: .never) var account: BillingAccount?
    @Parameter(title: "转出账户", inputConnectionBehavior: .never) var sourceAccount: BillingAccount?
    @Parameter(title: "转入账户", inputConnectionBehavior: .never) var destinationAccount: BillingAccount?
    @Parameter(title: "时间", inputConnectionBehavior: .never) var date: Date?
    @Parameter(title: "备注", inputConnectionBehavior: .never) var note: String?
    @Parameter(title: "不计预算（是／否）", inputConnectionBehavior: .never) var excluded: String?
    @Parameter(title: "原始文本", inputConnectionBehavior: .never) var originalText: String?
    @Parameter(title: "支付截屏", inputConnectionBehavior: .never) var screenshot: IntentFile?
    static var parameterSummary: some ParameterSummary {
        Summary("准备账单") {
            \.$amount; \.$type; \.$ledger; \.$category; \.$tag; \.$account
            \.$sourceAccount; \.$destinationAccount; \.$date; \.$note
            \.$excluded; \.$originalText; \.$screenshot
        }
    }
    @MainActor func perform() async throws -> some IntentResult & ReturnsValue<VariableBillingDraft> {
        .result(value: try await VariableBillingFlow.prepare(amount: amount, type: type, ledgerId: ledger?.id,
            category: category, tag: tag, accountId: account?.id, sourceAccountId: sourceAccount?.id,
            destinationAccountId: destinationAccount?.id, date: date, note: note, excluded: excluded,
            originalText: originalText, screenshot: screenshot))
    }
}

@available(iOS 16.0, *)
struct ConfirmVariableBillingIntent: AppIntent {
    static var isDiscoverable = true
    static var title: LocalizedStringResource = "确认并记账"
    static var description: LocalizedStringResource = "查看并逐项修改待确认账单；标签点击轮换，确认后按最终值保存一条。取消不入账，不调用 AI。"
    static var openAppWhenRun = false
    @Parameter(title: "待确认账单") var bill: VariableBillingDraft
    // These are prompt slots owned by this intent, not extra user-built actions.
    @Parameter(title: "菜单", inputConnectionBehavior: .never) var choice: String?
    @Parameter(title: "修改金额", inputConnectionBehavior: .never) var editingAmount: Double?
    @Parameter(title: "修改备注", inputOptions: String.IntentInputOptions(multiline: true), inputConnectionBehavior: .never) var editingNote: String?
    @Parameter(title: "修改时间", inputConnectionBehavior: .never) var editingDate: Date?
    static var parameterSummary: some ParameterSummary { Summary("确认并记账 \(\.$bill)") }
    @MainActor func perform() async throws -> some IntentResult & ReturnsValue<String> & ProvidesDialog {
        let outcome = try await VariableBillingFlow.review(bill, choose: { values, prompt in
            try await $choice.requestDisambiguation(among: values, dialog: IntentDialog(stringLiteral: prompt))
        }, readAmount: { current, digits in
            editingAmount = nil
            // Deliberately no dynamic prefill promise. Current value is visible in the dialog/menu.
            let value = try await $editingAmount.requestValue(IntentDialog(stringLiteral: "请输入新金额；当前：" + current))
            return try VariableBillingFlow.amountText(value, digits: digits)
        }, readNote: { current in
            editingNote = current
            return try await $editingNote.requestValue(IntentDialog(stringLiteral: "修改备注（可留空）；当前备注：" + current))
        }, readDate: { current in
            editingDate = current
            return try await $editingDate.requestValue("修改账单时间")
        })
        return .result(value: outcome.value, dialog: IntentDialog(stringLiteral: outcome.message))
    }
}

@available(iOS 16.0, *)
@MainActor
enum VariableBillingFlow {
    struct Outcome {
        let value: String
        let message: String
    }
    static func trimmed(_ text: String?) -> String {
        (text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    }
    static func transactionType(_ text: String?) -> String? {
        switch trimmed(text).lowercased() {
        case "", "支出", "expense": return "expense"
        case "收入", "income": return "income"
        case "转账", "transfer": return "transfer"
        default: return nil
        }
    }
    static func typeName(_ type: String) -> String {
        type == "income" ? "收入" : type == "transfer" ? "转账" : "支出"
    }
    static func budgetFlag(_ text: String?) -> Bool? {
        switch trimmed(text) {
        case "", "否": return false
        case "是": return true
        default: return nil
        }
    }
    static func amountText(_ value: Double, digits: Int) throws -> String {
        guard value.isFinite, let decimal = Decimal(string: String(value), locale: Locale(identifier: "en_US_POSIX")) else {
            throw ShortcutBillingError(message: "金额无效，请输入正金额")
        }
        let text = NSDecimalNumber(decimal: decimal).stringValue
        _ = try ConfirmedBilling.minor(text, digits: digits)
        return text
    }
    static func categoryMatches(_ name: String, options: [[String: Any]]) -> [[String: Any]] {
        let value = trimmed(name)
        // Both a full path and a bare child name may match. Never prefer an arbitrary duplicate.
        return options.filter { row in
            let path = row["name"] as? String ?? ""
            let leaf = row["leafName"] as? String ?? path.components(separatedBy: "/").last ?? path
            return value == path || value == leaf
        }
    }
    static func prepare(amount: String?, type: String?, ledgerId: Int?, category: String?, tag: String?,
                        accountId: Int?, sourceAccountId: Int?, destinationAccountId: Int?, date: Date?,
                        note: String?, excluded: String?, originalText: String?, screenshot: IntentFile?,
                        call: ([String: Any]) async throws -> [String: Any] = ConfirmedBilling.call) async throws -> VariableBillingDraft {
        guard (note ?? "").utf8.count <= 10000, (originalText ?? "").utf8.count <= 50000,
              [type, category, tag, excluded].allSatisfy({ ($0 ?? "").utf8.count <= 1000 }) else {
            throw ShortcutBillingError(message: "传入文字过长，未生成账单")
        }
        let resolvedType = transactionType(type)
        let effectiveType = resolvedType ?? "expense"
        var request: [String: Any] = ["operation": "options", "type": effectiveType]
        if let ledgerId { request["ledgerId"] = ledgerId }
        let options = try await call(request)
        guard let ledger = options["ledgerId"] as? Int, let currency = options["currency"] as? String,
              let digits = options["minorDigits"] as? Int, (0...4).contains(digits) else {
            throw ShortcutBillingError(message: "账本选项无效，请检查 App 当前账本")
        }
        var payload: [String: Any] = ["variableBillingVersion": 1, "requestId": UUID().uuidString,
            "ledgerId": ledger, "currency": currency, "minorDigits": digits, "type": effectiveType,
            "note": note ?? "", "tagIds": [Int](), "excludeFromBudget": budgetFlag(excluded) ?? false,
            "originalText": originalText ?? ""]
        if resolvedType == nil { payload["pendingType"] = trimmed(type) }
        if budgetFlag(excluded) == nil { payload["pendingBudget"] = trimmed(excluded) }
        let suppliedAmount = trimmed(amount)
        if !suppliedAmount.isEmpty {
            if let minor = try? ConfirmedBilling.minor(suppliedAmount, digits: digits) { payload["amountMinor"] = minor }
            else { payload["pendingAmount"] = String(suppliedAmount.prefix(100)) }
        }
        if let date { payload["occurredAt"] = ISO8601DateFormatter().string(from: date) }
        if effectiveType == "transfer" {
            if let sourceAccountId { payload["accountId"] = sourceAccountId }
            if let destinationAccountId { payload["toAccountId"] = destinationAccountId }
        } else if let accountId { payload["accountId"] = accountId }
        let categoryName = trimmed(category)
        if effectiveType != "transfer" {
            let categories = options["categories"] as? [[String: Any]] ?? []
            if !categoryName.isEmpty {
                let matches = categoryMatches(categoryName, options: categories)
                if matches.count == 1 { payload["categoryId"] = matches[0]["id"] }
                else { payload["pendingCategory"] = categoryName }
            } else if resolvedType != nil && (!trimmed(note).isEmpty || !trimmed(originalText).isEmpty) {
                let matched = try await call(["operation": "classify", "type": effectiveType, "ledgerId": ledger,
                    "note": note ?? "", "ruleText": originalText ?? "", "merchant": ""])
                if let id = matched["categoryId"] as? Int, categories.contains(where: { $0["id"] as? Int == id }) { payload["categoryId"] = id }
            }
        }
        let tagName = trimmed(tag)
        if !tagName.isEmpty {
            let matches = (options["tags"] as? [[String: Any]] ?? []).filter { $0["name"] as? String == tagName }
            if matches.count == 1, let id = matches[0]["id"] as? Int { payload["tagIds"] = [id] }
            else { payload["pendingTag"] = tagName }
        }
        // Screenshot remains an IntentFile in the transient entity, not a path or encoded JSON image.
        return VariableBillingDraft(payload: try ConfirmedBilling.encode(payload), screenshot: screenshot)
    }

    static func review(_ bill: VariableBillingDraft,
                       choose: ([String], String) async throws -> String,
                       readAmount: (String, Int) async throws -> String,
                       readNote: (String) async throws -> String,
                       readDate: (Date?) async throws -> Date,
                       call: ([String: Any]) async throws -> [String: Any] = ConfirmedBilling.call,
                       commit: ([String: Any], IntentFile?) async throws -> String = { try await ConfirmedBilling.commit($0, attachment: $1) }) async throws -> Outcome {
        var state = try ConfirmedBilling.decode(bill.payload)
        guard state["variableBillingVersion"] as? Int == 1,
              let requestID = state["requestId"] as? String, UUID(uuidString: requestID) != nil,
              let initialLedger = state["ledgerId"] as? Int,
              let initialType = state["type"] as? String, ["expense", "income", "transfer"].contains(initialType),
              state["note"] is String, (state["note"] as? String ?? "").utf8.count <= 10000,
              state["tagIds"] is [Int], (state["tagIds"] as? [Int] ?? []).count <= 1,
              state["excludeFromBudget"] is Bool else {
            throw ShortcutBillingError(message: "请把准备账单的待确认账单连接到此动作，不要只传文字属性")
        }
        var options = try await call(["operation": "options", "ledgerId": initialLedger, "type": initialType])
        func rows(_ key: String) -> [[String: Any]] { options[key] as? [[String: Any]] ?? [] }
        func has(_ id: Int?, in key: String) -> Bool { rows(key).contains { $0["id"] as? Int == id } }
        func pick(_ values: [[String: Any]], title: String, current: Int? = nil, allowNone: Bool = false) async throws -> Int? {
            let labels = values.enumerated().map { index, row in
                (row["id"] as? Int == current ? "✓ " : "") + String(index + 1) + ". " + (row["name"] as? String ?? "")
            }
            let selected = try await choose(labels + (allowNone ? ["不分类"] : []) + ["返回"], title)
            if selected == "不分类" { return nil }
            guard let index = labels.firstIndex(of: selected), let id = values[index]["id"] as? Int else { throw CancellationError() }
            return id
        }
        func selectCategory() async throws -> Int? {
            let categories = rows("categories")
            // Backend returns only usable leaf categories. Build non-selectable parent groups
            // from their metadata; never submit a parent that owns child categories.
            var parents: [[String: Any]] = []
            for row in categories {
                if let parentID = row["parentId"] as? Int {
                    if !parents.contains(where: { $0["id"] as? Int == parentID }) {
                        let name = row["parentName"] as? String ?? (row["name"] as? String ?? "").components(separatedBy: "/").first ?? ""
                        parents.append(["id": parentID, "name": name])
                    }
                } else { parents.append(row) }
            }
            if parents.isEmpty { return try await pick([], title: "没有可用分类，可保留未分类", allowNone: true) }
            while true {
                let current = state["categoryId"] as? Int
                let currentRow = categories.first { $0["id"] as? Int == current }
                let currentParent = currentRow?["parentId"] as? Int ?? current
                let parent = try await pick(parents, title: "选择一级分类", current: currentParent, allowNone: true)
                guard let parent else { return nil }
                let children = categories.filter { $0["parentId"] as? Int == parent }
                if children.isEmpty { return parent }
                do { return try await pick(children, title: "选择二级分类", current: current) }
                catch is CancellationError { continue }
            }
        }
        func cancelled() throws -> Outcome {
            Outcome(value: try ConfirmedBilling.encode(["status": "cancelled"]), message: "已取消，未入账")
        }
        func revalidateReferences() {
            if !has(state["accountId"] as? Int, in: "accounts") { state.removeValue(forKey: "accountId") }
            if !has(state["toAccountId"] as? Int, in: "accounts") { state.removeValue(forKey: "toAccountId") }
            if let id = state["categoryId"] as? Int, !has(id, in: "categories") { state.removeValue(forKey: "categoryId"); state["pendingCategory"] = "原分类已失效，请重新选择" }
            if let id = (state["tagIds"] as? [Int])?.first, !has(id, in: "tags") { state["tagIds"] = [Int](); state["pendingTag"] = "原标签已失效，请重新选择" }
        }
        if state["currency"] as? String != options["currency"] as? String || state["minorDigits"] as? Int != options["minorDigits"] as? Int {
            state.removeValue(forKey: "amountMinor")
            state["pendingAmount"] = "账本币种或精度已变化，请重新填写"
        }
        revalidateReferences()
        while true {
            if Task.isCancelled { return try cancelled() }
            let type = state["type"] as? String ?? "expense"
            guard let ledgerId = options["ledgerId"] as? Int, let currency = options["currency"] as? String,
                  let digits = options["minorDigits"] as? Int, (0...4).contains(digits) else { throw ShortcutBillingError(message: "账本选项无效，未入账") }
            let amount = state["amountMinor"] as? Int
            let amountLabel = amount.map { ConfirmedBilling.money($0, digits: digits) } ?? "待填写"
            let categoryLabel = (state["pendingCategory"] as? String).map { "待选择（" + $0 + "）" } ?? ((state["categoryId"] as? Int).map { ConfirmedBilling.label($0, rows("categories")) } ?? "未分类")
            let tagLabel = (state["pendingTag"] as? String).map { "待选择（" + $0 + "）" } ?? ((state["tagIds"] as? [Int] ?? []).first.map { ConfirmedBilling.label($0, rows("tags")) } ?? "无")
            let values: [String: String] = [
                "金额": amountLabel + " " + currency,
                "类型": (state["pendingType"] as? String).map { "待选择（" + $0 + "）" } ?? typeName(type),
                "账本": ConfirmedBilling.label(ledgerId, rows("ledgers")), "分类": categoryLabel, "标签": tagLabel,
                "账户": ConfirmedBilling.label(state["accountId"] as? Int, rows("accounts")),
                "转出账户": ConfirmedBilling.label(state["accountId"] as? Int, rows("accounts")),
                "转入账户": ConfirmedBilling.label(state["toAccountId"] as? Int, rows("accounts")),
                "时间": (state["occurredAt"] as? String).map(ConfirmedBilling.displayTime) ?? "待填写",
                "备注": state["note"] as? String ?? "",
                "不计预算": (state["pendingBudget"] as? String).map { "待选择（" + $0 + "）" } ?? (state["excludeFromBudget"] as? Bool == true ? "是" : "否")]
            var fields: [String] = ["金额", "类型", "账本"]
            if type != "transfer" { fields.append("分类") }
            fields.append("标签")
            if type == "transfer" { fields.append(contentsOf: ["转出账户", "转入账户"]) }
            else { fields.append("账户") }
            fields.append(contentsOf: ["时间", "备注"])
            if type == "expense" { fields.append("不计预算") }
            let labels = fields.map { $0 + "：" + (values[$0] ?? "") }
            let selected: String
            do { selected = try await choose(labels + ["确认提交", "取消提交"], "确认账单（修改后返回此菜单）") }
            catch is CancellationError { return try cancelled() }
            let action = labels.firstIndex(of: selected).map { fields[$0] } ?? selected
            do {
                switch action {
                case "取消提交": return try cancelled()
                case "金额":
                    let text = try await readAmount(amountLabel, digits)
                    state["amountMinor"] = try ConfirmedBilling.minor(text, digits: digits)
                    state.removeValue(forKey: "pendingAmount")
                case "备注":
                    let text = try await readNote(state["note"] as? String ?? "")
                    guard text.utf8.count <= 10000 else { throw ShortcutBillingError(message: "备注过长，已保留原值") }
                    state["note"] = text
                case "标签":
                    let tags = rows("tags")
                    if state["pendingTag"] != nil {
                        let id = try await pick(tags, title: "传入标签不存在或重名，请选择")
                        state["tagIds"] = id.map { [$0] } ?? []
                        state.removeValue(forKey: "pendingTag")
                    } else { state["tagIds"] = ConfirmedBilling.nextTag(state["tagIds"] as? [Int] ?? [], tags: tags) }
                case "分类":
                    state["categoryId"] = try await selectCategory()
                    state.removeValue(forKey: "pendingCategory")
                case "不计预算":
                    let value = try await choose(["是", "否", "返回"], "不计预算")
                    if value == "是" || value == "否" { state["excludeFromBudget"] = value == "是"; state.removeValue(forKey: "pendingBudget") }
                case "账户", "转出账户":
                    state["accountId"] = try await pick(rows("accounts"), title: action, current: state["accountId"] as? Int)
                    if state["toAccountId"] as? Int == state["accountId"] as? Int { state.removeValue(forKey: "toAccountId") }
                case "转入账户":
                    state["toAccountId"] = try await pick(rows("accounts").filter { $0["id"] as? Int != state["accountId"] as? Int }, title: "选择转入账户", current: state["toAccountId"] as? Int)
                case "时间":
                    let current = (state["occurredAt"] as? String).flatMap { ISO8601DateFormatter().date(from: $0) }
                    let date = try await readDate(current)
                    guard (2000...2200).contains(Calendar(identifier: .gregorian).component(.year, from: date)) else { throw ShortcutBillingError(message: "日期超出范围，已保留原时间") }
                    state["occurredAt"] = ISO8601DateFormatter().string(from: date)
                case "类型":
                    let value = try await choose(["支出", "收入", "转账", "返回"], "选择账单类型")
                    if value == "返回" { continue }
                    guard let nextType = transactionType(value) else { continue }
                    if nextType != type || state["pendingType"] != nil {
                        let fresh = try await call(["operation": "options", "ledgerId": ledgerId, "type": nextType])
                        state["type"] = nextType
                        state.removeValue(forKey: "categoryId"); state.removeValue(forKey: "pendingCategory")
                        state.removeValue(forKey: "toAccountId"); state.removeValue(forKey: "pendingType")
                        options = fresh
                        revalidateReferences()
                    }
                case "账本":
                    guard let nextLedger = try await pick(rows("ledgers"), title: "选择账本", current: ledgerId), nextLedger != ledgerId else { continue }
                    let fresh = try await call(["operation": "options", "ledgerId": nextLedger, "type": type])
                    if fresh["currency"] as? String != currency || fresh["minorDigits"] as? Int != digits {
                        let choice = try await choose(["切换并重新填写金额", "返回"], "新账本币种或精度不同，不自动换算金额")
                        if choice != "切换并重新填写金额" { continue }
                        state.removeValue(forKey: "amountMinor")
                    }
                    options = fresh; state["ledgerId"] = nextLedger
                    revalidateReferences()
                case "确认提交":
                    options = try await call(["operation": "options", "ledgerId": ledgerId, "type": type])
                    if options["currency"] as? String != currency || options["minorDigits"] as? Int != digits {
                        state.removeValue(forKey: "amountMinor")
                        throw ShortcutBillingError(message: "账本币种或精度已变化，请重新填写金额")
                    }
                    revalidateReferences()
                    guard state["pendingType"] == nil, state["pendingTag"] == nil,
                          type == "transfer" || state["pendingCategory"] == nil,
                          type != "expense" || state["pendingBudget"] == nil else { throw ShortcutBillingError(message: "请先纠正待选择的类型、分类、标签或预算标记") }
                    guard let finalAmount = state["amountMinor"] as? Int, finalAmount > 0, finalAmount <= 999999999999 else { throw ShortcutBillingError(message: "请先填写有效金额") }
                    guard let finalAccount = state["accountId"] as? Int, has(finalAccount, in: "accounts") else { throw ShortcutBillingError(message: "请先选择有效账户") }
                    guard let time = state["occurredAt"] as? String else { throw ShortcutBillingError(message: "请传入时间或点击时间补齐，不会擅自使用当前时间") }
                    if type == "transfer" {
                        guard let destination = state["toAccountId"] as? Int, has(destination, in: "accounts"), destination != finalAccount else { throw ShortcutBillingError(message: "请选择两个不同的有效转账账户") }
                    }
                    let entry: [String: Any] = ["amountMinor": finalAmount, "note": state["note"] as? String ?? "",
                        "tagIds": state["tagIds"] as? [Int] ?? [], "excludeFromBudget": type == "expense" && state["excludeFromBudget"] as? Bool == true]
                    var finalEntry = entry
                    if type != "transfer", let categoryId = state["categoryId"] as? Int { finalEntry["categoryId"] = categoryId }
                    var submission: [String: Any] = ["schemaVersion": 1, "confirmed": true, "requestId": requestID,
                        "ledgerId": ledgerId, "currency": currency, "type": type, "accountId": finalAccount,
                        "occurredAt": time, "originalAmountMinor": finalAmount, "entries": [finalEntry]]
                    if type == "transfer" { submission["toAccountId"] = state["toAccountId"] }
                    _ = try await call(["operation": "validate", "submission": submission])
                    try Task.checkCancellation()
                    // Encode attachment once at confirmation; retries retain this exact payload and request ID.
                    if let screenshot = bill.screenshot { submission["attachment"] = try ConfirmedBilling.attachmentPayload(screenshot) }
                    while true {
                        do {
                            try Task.checkCancellation()
                            let saved = try await commit(submission, nil)
                            let response = try ConfirmedBilling.decode(saved)
                            guard response["status"] as? String == "committed" else { throw ShortcutBillingError(message: "尚未收到已入账凭证") }
                            return Outcome(value: saved, message: "已在本机入账 1 条，合计 " + ConfirmedBilling.money(finalAmount, digits: digits) + " " + currency + "。云端同步请查看 App，无需重记。")
                        } catch {
                            let next: String
                            do { next = try await choose(["查询并重试原账单", "结束并稍后核对"], "提交结果未完成或不明；不要重新运行准备账单。" + error.localizedDescription) }
                            catch { return Outcome(value: try ConfirmedBilling.encode(["status": "unknown", "requestId": requestID]), message: "结果未确认，请查看 App 最近提交凭证及账单，不要重复记账") }
                            if next != "查询并重试原账单" { return Outcome(value: try ConfirmedBilling.encode(["status": "unknown", "requestId": requestID]), message: "结果未确认，请查看 App 最近提交凭证及账单，不要重复记账") }
                            // Query is diagnostic only: a receipt for this ID alone cannot prove
                            // it corresponds to these final edited values. Recommit the identical
                            // payload so the store verifies its canonical digest before success.
                            _ = try? await call(["operation": "query", "requestId": requestID])
                        }
                    }
                default: throw ShortcutBillingError(message: "菜单选项已失效，请重新选择")
                }
            } catch is CancellationError { continue }
            catch {
                do { _ = try await choose(["返回账单"], error.localizedDescription) }
                catch is CancellationError { return try cancelled() }
            }
        }
    }
}

#endif
