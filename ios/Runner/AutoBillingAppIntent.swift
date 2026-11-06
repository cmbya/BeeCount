import Foundation
import CryptoKit
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
        AppShortcut(
            intent: ImageConfirmBillingIntent(),
            phrases: [
                "在\(.applicationName)中截图记账",
                "用\(.applicationName)记账",
                "打开\(.applicationName)自动记账"
            ]
        )
        AppShortcut(
            intent: TextConfirmBillingIntent(),
            phrases: ["用\(.applicationName)文字记账"]
        )
    }
}
// MARK: - Confirmed shortcut billing (separate from the legacy automatic action)

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
            throw ShortcutBillingError(message: "结果尚未确认。请求 ID：" + id + "。请运行查询快捷记账结果，勿更换 ID 重记。")
        }
        throw ShortcutBillingError(message: (response["message"] as? String ?? "提交未完成") + " 请求 ID：" + id)
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

@available(iOS 16.0, *)
struct BillingOptionsIntent: AppIntent {
    static var isDiscoverable: Bool = false
    static var title: LocalizedStringResource = "获取快捷记账选项"
    static var openAppWhenRun = false
    @Parameter(title: "账本 ID") var ledgerId: Int?
    @Parameter(title: "类型 expense/income/transfer", default: "expense") var type: String
    @MainActor func perform() async throws -> some IntentResult & ReturnsValue<String> {
        var input: [String: Any] = ["operation": "options", "type": type]
        if let ledgerId { input["ledgerId"] = ledgerId }
        return .result(value: try ConfirmedBilling.encode(await ConfirmedBilling.call(input)))
    }
}

@available(iOS 16.0, *)
struct ImageBillingDraftIntent: AppIntent {
    static var isDiscoverable: Bool = false
    static var title: LocalizedStringResource = "图片生成记账草稿"
    static var description: LocalizedStringResource = "仅识别，不入账。图片将发送给 App 配置的视觉服务。"
    static var openAppWhenRun = false
    @Parameter(title: "图片") var image: IntentFile
    @Parameter(title: "默认配置 JSON") var configuration: String?
    @MainActor func perform() async throws -> some IntentResult & ReturnsValue<String> {
        return .result(value: try ConfirmedBilling.encode(await ConfirmedBilling.recognizeImage(image, ocr: false, configuration: configuration)))
    }
}

@available(iOS 16.0, *)
struct TextBillingDraftIntent: AppIntent {
    static var isDiscoverable: Bool = false
    static var title: LocalizedStringResource = "文字生成记账草稿"
    static var description: LocalizedStringResource = "仅识别，不入账。只发送文字给 App 配置的文字服务，不发送原图。"
    static var openAppWhenRun = false
    @Parameter(title: "OCR 文字") var text: String
    @Parameter(title: "默认配置 JSON") var configuration: String?
    @MainActor func perform() async throws -> some IntentResult & ReturnsValue<String> {
        var input = try configuration.map(ConfirmedBilling.decode) ?? [:]
        input["operation"] = "recognize"; input["mode"] = "text"; input["text"] = text
        input["timeZoneOffsetSeconds"] = TimeZone.current.secondsFromGMT()
        return .result(value: try ConfirmedBilling.encode(await ConfirmedBilling.call(input)))
    }
}

@available(iOS 16.0, *)
struct CommitConfirmedBillingIntent: AppIntent {
    static var isDiscoverable: Bool = false
    static var title: LocalizedStringResource = "提交已确认账单"
    static var openAppWhenRun = false
    @Parameter(title: "已确认账单 JSON") var submission: String
    @MainActor func perform() async throws -> some IntentResult & ReturnsValue<String> {
        return .result(value: try await ConfirmedBilling.commit(ConfirmedBilling.decode(submission)))
    }
}

@available(iOS 16.0, *)
struct QueryConfirmedBillingIntent: AppIntent {
    static var isDiscoverable: Bool = false
    static var title: LocalizedStringResource = "查询快捷记账结果"
    static var openAppWhenRun = false
    @Parameter(title: "请求 ID（留空查最近一次）") var requestId: String?
    @MainActor func perform() async throws -> some IntentResult & ReturnsValue<String> {
        let id = requestId ?? UserDefaults.standard.string(forKey: "confirmedBillingLastRequestId")
        let input: [String: Any] = id.map { ["operation": "query", "requestId": $0] } ?? ["operation": "recent"]
        return .result(value: try ConfirmedBilling.encode(await ConfirmedBilling.call(input)))
    }
}

// MARK: - Shortcuts-owned Ask for Input transport
// No on-disk draft: the Shortcuts variable carries this invocation's transcript.
// Replaying menu/options responses restores nested split editing without rerunning AI.
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
    static func start(_ draft: String, showIncompleteDraft: Bool = false, singleOnly: Bool = false) throws -> String {
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
        let state: [String: Any] = ["version": 1, "draft": try ConfirmedBilling.encode(object), "events": [[String: String]](), "showIncompleteDraft": showIncompleteDraft, "singleOnly": singleOnly]
        return try ConfirmedBilling.encode(["status": "editing", "state": ConfirmedBilling.encode(state)])
    }

    static func advance(_ envelope: String, response: String?, hasResponse: Bool,
                        choose: @escaping ([String], String) async throws -> String,
                        call: @escaping ([String: Any]) async throws -> [String: Any] = ConfirmedBilling.call) async throws -> String {
        let outer = try ConfirmedBilling.decode(envelope)
        guard ["editing", "input"].contains(outer["status"] as? String ?? ""),
              let encodedState = outer["state"] as? String else { throw ShortcutBillingError(message: "请传入上一次编辑步骤的完整结果") }
        let state = try ConfirmedBilling.decode(encodedState)
        let progressive = outer["splitContext"] as? [String: Any]
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
        }, input: { _ in throw ShortcutBillingError(message: "模板模式不能调用旧系统输入") }, externalInput: { request in
            let key = try ConfirmedBilling.encode(request.payload)
            return try await replay.recorded("input", request: key) { throw BillingInputSuspension(request: request) }
        }, showIncompleteDraft: state["showIncompleteDraft"] as? Bool ?? false, singleOnly: state["singleOnly"] as? Bool ?? false, progressive: progressive, call: { payload in
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
            let result = try ConfirmedBilling.decode(submission)
            if result["progressiveSplitStart"] as? Bool == true {
                return try ConfirmedBilling.encode(["status": "split-start", "submission": submission, "singleOnly": true])
            }
            var envelope: [String: Any] = ["status": progressive == nil ? "confirmed" : "split-confirmed", "submission": submission,
                "singleOnly": state["singleOnly"] as? Bool ?? false]
            if let progressive { envelope["splitContext"] = progressive }
            return try ConfirmedBilling.encode(envelope)
        } catch let pending as BillingInputSuspension {
            let next: [String: Any] = ["version": 1, "draft": draft, "events": replay.events, "showIncompleteDraft": state["showIncompleteDraft"] as? Bool ?? false, "singleOnly": state["singleOnly"] as? Bool ?? false]
            var envelope: [String: Any] = ["status": "input", "state": try ConfirmedBilling.encode(next), "input": pending.request.payload]
            if let progressive { envelope["splitContext"] = progressive }
            return try ConfirmedBilling.encode(envelope)
        } catch is CancellationError {
            return try ProgressiveSplitFlow.cancelled(progressive)
        } catch let error as ShortcutBillingError where error.message == "已取消，未入账" {
            return try ProgressiveSplitFlow.cancelled(progressive)
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
        case let .finished(saved): return plain(saved, dialog: try CustomBilling.result(saved))
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
struct ContinueBillingStepIntent: AppIntent {
    static var title: LocalizedStringResource = "继续账单确认（模板）"
    static var description: LocalizedStringResource = "组合快捷指令专用：显示确认菜单，需要文字或金额时返回给系统询问输入。此动作不入账。"
    static var openAppWhenRun = false
    @Parameter(title: "上一步结果") var state: String
    @Parameter(title: "输入结果", inputConnectionBehavior: .never) var response: String?
    @Parameter(title: "已提供输入", default: false) var hasResponse: Bool
    @Parameter(title: "菜单", inputConnectionBehavior: .never) var choice: String?
    static var parameterSummary: some ParameterSummary {
        Summary("继续账单确认 \(\.$state)") { \.$response; \.$hasResponse }
    }
    @MainActor func perform() async throws -> some IntentResult & ReturnsValue<String> {
        .result(value: try await BillingStepFlow.advance(state, response: response, hasResponse: hasResponse, choose: { values, prompt in
            try await $choice.requestDisambiguation(among: values, dialog: IntentDialog(stringLiteral: prompt))
        }))
    }
}

@available(iOS 16.0, *)
struct SaveBillingStepIntent: AppIntent {
    static var title: LocalizedStringResource = "保存已确认账单（模板）"
    static var openAppWhenRun = false
    @Parameter(title: "确认结果") var state: String
    @Parameter(title: "附带图片", inputConnectionBehavior: .never) var attachment: IntentFile?
    static var parameterSummary: some ParameterSummary { Summary("保存 \(\.$state)") { \.$attachment } }
    @MainActor func perform() async throws -> some IntentResult & ReturnsValue<String> & ProvidesDialog {
        let envelope = try ConfirmedBilling.decode(state)
        guard envelope["status"] as? String == "confirmed", let submission = envelope["submission"] as? String else { throw ShortcutBillingError(message: "账单尚未确认，不可保存") }
        let saved = try await ConfirmedBilling.commit(ConfirmedBilling.decode(submission), attachment: attachment)
        return .result(value: saved, dialog: try CustomBilling.result(saved))
    }
}

@available(iOS 16.0, *)
struct EditBillingDraftIntent: AppIntent {
    static var isDiscoverable: Bool = false
    static var title: LocalizedStringResource = "确认编辑记账草稿"
    static var description: LocalizedStringResource = "系统菜单编辑、逐笔拆分并最终确认。此动作本身不入账。"
    static var openAppWhenRun = false
    @Parameter(title: "草稿 JSON") var draft: String
    @Parameter(title: "菜单选择", inputConnectionBehavior: .never) var choice: String?
    @Parameter(title: "输入内容", default: "", inputConnectionBehavior: .never) var textValue: String

    @MainActor func perform() async throws -> some IntentResult & ReturnsValue<String> {
        .result(value: try await runEditor())
    }

    @MainActor func runEditor() async throws -> String {
        let editor = ConfirmedBillingEditor(draft: draft, choose: { values, prompt in
            try await $choice.requestDisambiguation(among: values, dialog: IntentDialog(stringLiteral: prompt))
        }, input: { prompt in
            textValue = ""
            return try await ConfirmedBilling.requestText($textValue, prompt: prompt)
        })
        return try await editor.runEditor()
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
    let singleOnly: Bool
    let progressive: [String: Any]?

    init(draft: String,
         choose: @escaping ([String], String) async throws -> String,
         input: @escaping (String) async throws -> String,
         externalInput: ((BillingInputRequest) async throws -> String)? = nil,
         showIncompleteDraft: Bool = false,
         singleOnly: Bool = false,
         progressive: [String: Any]? = nil,
         call: @escaping ([String: Any]) async throws -> [String: Any] = ConfirmedBilling.call) {
        self.draft = draft; self.choose = choose; self.input = input; self.call = call
        self.externalInput = externalInput
        self.showIncompleteDraft = showIncompleteDraft
        self.singleOnly = singleOnly
        self.progressive = progressive
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
    private func selectTags(_ current: [Int], options: [[String: Any]]) async throws -> [Int] {
        let original = Array(Set(current)).sorted()
        var selected = Set(current)
        while true {
            let labels = options.map { row in
                (selected.contains(row["id"] as? Int ?? -1) ? "✓ " : "○ ") + (row["name"] as? String ?? "") + " [" + String(row["id"] as? Int ?? -1) + "]"
            }
            let action = try await choose(["完成标签选择", "清空标签", "返回不修改"] + labels, "选择标签（可多选，点选切换状态）")
            if action == "完成标签选择" { return selected.sorted() }
            if action == "清空标签" { selected.removeAll(); continue }
            if action == "返回不修改" { return original }
            guard let index = labels.firstIndex(of: action), let id = options[index]["id"] as? Int else {
                throw ShortcutBillingError(message: "标签选项已失效，未入账")
            }
            if selected.contains(id) { selected.remove(id) } else { selected.insert(id) }
        }
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
        if let progressive {
            _ = try ProgressiveSplitFlow.context(progressive)
            guard type == "expense", ledgerId == (progressive["ledgerId"] as? Int),
                  currency == (progressive["currency"] as? String),
                  (candidate["accountId"] as? Int) == (progressive["accountId"] as? Int) else {
                throw ShortcutBillingError(message: "拆分的账本、账户、币种和类型已锁定；不会修改已保存账单")
            }
        }
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
        if let progressive, accountId == nil {
            throw ShortcutBillingError(message: try ProgressiveSplitFlow.summary(progressive) + "\n原付款账户已失效或不可用，当前笔未保存，已保存账单保留。请先在 App 处理账户，不得换账户继续此会话。")
        }
        var time = candidate["occurredAt"] as? String ?? source["editorTime"] as? String ?? ISO8601DateFormatter().string(from: Date())
        var entries: [[String: Any]] = [["amountMinor": total, "note": candidate["note"] as? String ?? "",
            "tagIds": singleOnly ? Array(Set(candidate["tagIds"] as? [Int] ?? defaults["tagIds"] as? [Int] ?? [])).sorted() : Array((candidate["tagIds"] as? [Int] ?? defaults["tagIds"] as? [Int] ?? []).prefix(1)),
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
            let actions: [String]
            let menuTitle: String
            if let progressive {
                actions = directFields.filter { $0 != "账户" } + ["确认保存此笔", "放弃当前笔并结束", "刷新有效选项"]
                menuTitle = try ProgressiveSplitFlow.summary(progressive) + "\n编辑第 " + String((progressive["savedCount"] as? Int ?? 0) + 1) + " 笔 · " + accountSummary
            } else {
                actions = directFields + (type == "transfer" ? ["转入账户"] : []) +
                    (type == "expense" ? (singleOnly ? ["拆分并逐笔保存"] : ["拆分或新增明细"]) : []) +
                    ["账本", "收支类型", "确认提交", "取消提交", "刷新有效选项"]
                menuTitle = singleOnly ? "单笔确认（最终确认才入账）\n" + typeName(type) + " · " + currency : single ? "确认" + typeName(type) + "信息" : summary
            }
            let selected = try await fields(actions, title: menuTitle, values: [
                "金额": total > 0 ? ConfirmedBilling.money(total, digits: digits) : "待填写", "分类": entry["categoryId"] == nil ? "未分类" : ConfirmedBilling.label(entry["categoryId"] as? Int, categories),
                "账户": ConfirmedBilling.label(accountId, accounts), "转入账户": ConfirmedBilling.label(toAccountId, accounts),
                "时间": ConfirmedBilling.displayTime(time), "备注": entry["note"] as? String ?? "", "标签": tagNames.isEmpty ? "无" : tagNames,
                "不计预算": entry["excludeFromBudget"] as? Bool == true ? "不计入预算" : "计入预算",
                "账本": ledgerName, "收支类型": typeName(type)
            ])
            let action = ["金额": "修改原付款金额", "账户": "记账账户", "时间": "日期时间", "取消提交": "取消整次记账", "放弃当前笔并结束": "取消整次记账", "确认保存此笔": "确认提交"][selected] ?? selected
            if progressive != nil && ["账本", "收支类型", "记账账户", "转入账户", "拆分并逐笔保存", "拆分或新增明细", "编辑明细", "删除明细"].contains(action) {
                throw ShortcutBillingError(message: "逐笔拆分不能修改已锁定的总额、账本、账户或类型；已保存账单保留")
            }
            switch action {
            case "拆分并逐笔保存":
                guard singleOnly, progressive == nil, type == "expense", total > 0, total <= 999999999999 else {
                    _ = try await choose(["返回账单"], "请先填写有效的支出总额，再拆分")
                    continue
                }
                guard let id = accountId, accounts.contains(where: { $0["id"] as? Int == id }) else {
                    accountId = try await pick(accounts, "拆分前选择付款账户")
                    continue
                }
                return try ConfirmedBilling.encode(["schemaVersion": 1, "progressiveSplitStart": true, "confirmed": false,
                    "requestId": source["requestId"] as? String ?? UUID().uuidString,
                    "ledgerId": ledgerId, "accountId": id, "currency": currency, "type": "expense", "occurredAt": time,
                    "minorDigits": digits, "originalAmountMinor": total, "entries": entries])
            case "分类":
                if singleOnly {
                    let labels = categories.enumerated().map { String($0.offset + 1) + ". " + ($0.element["name"] as? String ?? "") }
                    let selected = try await choose(["不分类", "返回"] + labels, "选择分类")
                    if selected == "不分类" { entries[0].removeValue(forKey: "categoryId") }
                    else if let index = labels.firstIndex(of: selected) { entries[0]["categoryId"] = categories[index]["id"] }
                } else { entries[0]["categoryId"] = try await pick(categories, "选择分类") }
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
            case "标签":
                if singleOnly { entries[0]["tagIds"] = try await selectTags(entries[0]["tagIds"] as? [Int] ?? [], options: tags) }
                else { entries[0]["tagIds"] = ConfirmedBilling.nextTag(entries[0]["tagIds"] as? [Int] ?? [], tags: tags) }
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
                    if try await choose(["切换并重新填写金额", "返回"], singleOnly ? "新账本币种不同，不自动换算；切换后请重新填写金额，其他字段尽量保留" : "新账本币种不同，不自动换算；切换将清空拆分金额") == "返回" { continue }
                    total = 0
                    if !singleOnly {
                        while total <= 0 {
                            let value = try await ask("请输入新账本的原金额（" + newCurrency + "）", kind: "number")
                            total = (try? ConfirmedBilling.minor(value, digits: fresh["minorDigits"] as? Int ?? 2)) ?? 0
                        }
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
                    if !singleOnly { accountId = try await pick(accounts, "选择记账账户") }
                }
                if !accounts.contains(where: { $0["id"] as? Int == toAccountId }) { toAccountId = nil }
                if singleOnly {
                    if let id = entries[0]["categoryId"] as? Int, !categories.contains(where: { $0["id"] as? Int == id }) { entries[0].removeValue(forKey: "categoryId") }
                    let ids = Set(tags.compactMap { $0["id"] as? Int })
                    entries[0]["tagIds"] = (entries[0]["tagIds"] as? [Int] ?? []).filter { ids.contains($0) }
                }
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
                let value = try await ask(singleOnly ? "修改账单日期时间" : "输入完整日期时间，如 2026-11-05T18:30:00+08:00", current: time, kind: singleOnly ? "date" : "text")
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
                    if let progressive, amount > (progressive["totalMinor"] as? Int ?? 0) - (progressive["paidMinor"] as? Int ?? 0) {
                        _ = try await choose(["返回修改"], "此笔不能超过剩余未记金额，已保留原值")
                        continue
                    }
                    total = amount
                    if !didSplit && entries.count == 1 { entries[0]["amountMinor"] = amount }
                } else { _ = try await choose(["返回修改"], "请输入有效正金额") }
            case "拆分或新增明细":
                guard !singleOnly else { throw ShortcutBillingError(message: "本轮只支持单笔；逐笔拆分在第二轮接入，未入账") }
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
                if singleOnly && entries.count != 1 { throw ShortcutBillingError(message: "单笔流程不能提交多笔，未入账") }
                if let progressive {
                    let remaining = (progressive["totalMinor"] as? Int ?? 0) - (progressive["paidMinor"] as? Int ?? 0)
                    guard total > 0, total <= remaining,
                          progressive["useAllRemaining"] as? Bool != true || total == remaining else {
                        _ = try await choose(["返回修改"], "此笔须大于零、不超过余额；最后一笔须等于剩余未记金额")
                        continue
                    }
                }
                guard !entries.isEmpty, used == total, entries.allSatisfy({ entry in
                    (entry["amountMinor"] as? Int ?? 0) > 0 && (type == "transfer" || entry["categoryId"] == nil || categories.contains { $0["id"] as? Int == entry["categoryId"] as? Int })
                }) else { _ = try await choose(["返回修改"], "金额尚未分配完、超额或已选分类失效，不能提交"); continue }
                guard let confirmedAccountId = accountId, accounts.contains(where: { $0["id"] as? Int == confirmedAccountId }) else {
                    if let progressive {
                        throw ShortcutBillingError(message: try ProgressiveSplitFlow.summary(progressive) + "\n原付款账户已失效，当前笔未提交；已保存账单保留，不得换账户继续此会话。")
                    }
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
                if let progressive {
                    submission["split"] = ["sessionId": progressive["sessionId"]!,
                        "partIndex": (progressive["savedCount"] as? Int ?? 0) + 1, "totalMinor": progressive["totalMinor"]!]
                }
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
            for account in other["accounts"] as? [[String: Any]] ?? [] where !rows.contains(where: { $0["id"] as? Int == account["id"] as? Int }) { rows.append(account) }
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


@available(iOS 16.0, *)
struct BillingCategory: AppEntity {
    static var typeDisplayRepresentation: TypeDisplayRepresentation = "分类"
    static var defaultQuery = BillingCategoryQuery()
    var id: Int
    var name: String
    var displayRepresentation: DisplayRepresentation { DisplayRepresentation(title: "\(name)") }
}
@available(iOS 16.0, *)
struct BillingCategoryQuery: EntityStringQuery {
    @MainActor func suggestedEntities() async throws -> [BillingCategory] {
        let options = try await ConfirmedBilling.call(["operation": "options"])
        var rows = options["categories"] as? [[String: Any]] ?? []
        let income = try await ConfirmedBilling.call(["operation": "options", "type": "income"]); rows += income["categories"] as? [[String: Any]] ?? []
        rows = rows.map { row in var row = row; row["name"] = (row["kind"] as? String == "income" ? "收入 · " : "支出 · ") + (row["name"] as? String ?? ""); return row }
        return rows.compactMap { row in
            guard let id = row["id"] as? Int, let name = row["name"] as? String else { return nil }
            return BillingCategory(id: id, name: name)
        }
    }
    @MainActor func entities(for identifiers: [Int]) async throws -> [BillingCategory] {
        try await suggestedEntities().filter { identifiers.contains($0.id) }
    }
    @MainActor func entities(matching string: String) async throws -> [BillingCategory] {
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


@available(iOS 16.0, *)
@MainActor
enum CustomBilling {
    static func draft(type: String, ledger: BillingLedger?, category: BillingCategory?, amount: String?, date: Date?, note: String?, account: BillingAccount?, destination: BillingAccount? = nil, tags: [BillingTag]?, excluded: Bool = false, merchant: String? = nil, ruleText: String? = nil,
                      call: ([String: Any]) async throws -> [String: Any] = ConfirmedBilling.call) async throws -> String {
        var request: [String: Any] = ["operation": "options", "type": type]
        if let ledger { request["ledgerId"] = ledger.id }
        let options = try await call(request)
        let defaults = options["defaults"] as? [String: Any] ?? [:]
        var candidate: [String: Any] = ["type": type, "note": note ?? "", "excludeFromBudget": type == "expense" && excluded, "tagIds": tags?.map { $0.id } ?? defaults["tagIds"] as? [Int] ?? []]
        if let amount, !amount.isEmpty { candidate["amountMinor"] = try ConfirmedBilling.minor(amount, digits: options["minorDigits"] as? Int ?? 2) }
        if let category {
            // An explicit user choice always beats category rules.
            candidate["categoryId"] = category.id
        } else if type != "transfer", [note ?? "", merchant ?? "", ruleText ?? ""].contains(where: { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) {
            let matched = try await call(["operation": "classify", "type": type,
                "ledgerId": options["ledgerId"]!, "note": note ?? "",
                "merchant": merchant ?? "", "ruleText": ruleText ?? ""])
            if let id = matched["categoryId"] as? Int { candidate["categoryId"] = id }
            if let warnings = matched["warnings"] as? [String], !warnings.isEmpty { candidate["warnings"] = warnings }
        }
        if let account { candidate["accountId"] = account.id }
        if let destination { candidate["toAccountId"] = destination.id }
        candidate["occurredAt"] = ISO8601DateFormatter().string(from: date ?? Date())
        return try ConfirmedBilling.encode(["status": "draft", "requestId": UUID().uuidString, "ledgerId": options["ledgerId"]!, "currency": options["currency"]!, "candidates": [candidate]])
    }
    static func result(_ text: String) throws -> IntentDialog {
        let object = try ConfirmedBilling.decode(text)
        return IntentDialog(stringLiteral: "已入账 " + String(object["count"] as? Int ?? 0) + " 条，合计 " + ConfirmedBilling.money(object["totalAmountMinor"] as? Int ?? 0, digits: object["minorDigits"] as? Int ?? 2) + "。云端尚未确认，请查看 App 同步状态，无需重记。")
    }
}


@available(iOS 16.0, *)
struct CustomExpenseBillingIntent: AppIntent {
    // Manual preset action: no AI, always review before committing.
    static var isDiscoverable: Bool = true
    static var title: LocalizedStringResource = "自定义支出账单"
    static var description: LocalizedStringResource = "手动填写字段或接入快捷指令变量，不调用 AI；运行后弹出账单确认菜单，可修改，确认后直接入账。"
    static var openAppWhenRun = false
    @Parameter(title: "账本") var ledger: BillingLedger?
    @Parameter(title: "分类") var category: BillingCategory?
    @Parameter(title: "金额") var amount: String?
    @Parameter(title: "时间") var date: Date?
    @Parameter(title: "备注") var note: String?
    @Parameter(title: "商户（分类线索，可选）", inputConnectionBehavior: .never) var merchant: String?
    @Parameter(title: "原始全文（分类线索，可选）", inputConnectionBehavior: .never) var ruleText: String?
    @Parameter(title: "账户") var account: BillingAccount?
    @Parameter(title: "标签") var tags: [BillingTag]?
    @Parameter(title: "不计预算", default: false) var excluded: Bool
    @Parameter(title: "附带图片", inputConnectionBehavior: .never) var attachment: IntentFile?
    @Parameter(title: "系统询问输入模板模式", default: false) var templateMode: Bool
    @Parameter(title: "菜单", inputConnectionBehavior: .never) var choice: String?
    @Parameter(title: "输入", default: "", inputConnectionBehavior: .never) var textValue: String
    static var parameterSummary: some ParameterSummary {
        Summary("自定义支出账单") { \.$ledger; \.$category; \.$amount; \.$date; \.$note; \.$merchant; \.$ruleText; \.$account; \.$tags; \.$excluded; \.$attachment; \.$templateMode }
    }
    @MainActor func perform() async throws -> some IntentResult & ReturnsValue<String> & ProvidesDialog & OpensIntent {
        let draft = try await CustomBilling.draft(type: "expense", ledger: ledger, category: category, amount: amount, date: date, note: note, account: account, destination: nil, tags: tags, excluded: excluded, merchant: merchant, ruleText: ruleText)
        if templateMode { return BillingHandoff.plain(try BillingStepFlow.start(draft), dialog: IntentDialog("")) }
        let state = try BillingStepFlow.start(draft)
        return try await BillingHandoff.start(state, attachment: attachment, choose: { values, prompt in
            try await $choice.requestDisambiguation(among: values, dialog: IntentDialog(stringLiteral: prompt))
        })
    }
}


@available(iOS 16.0, *)
struct CustomIncomeBillingIntent: AppIntent {
    // Manual preset action: no AI, always review before committing.
    static var isDiscoverable: Bool = true
    static var title: LocalizedStringResource = "自定义收入账单"
    static var description: LocalizedStringResource = "手动填写字段或接入快捷指令变量，不调用 AI；运行后弹出账单确认菜单，可修改，确认后直接入账。"
    static var openAppWhenRun = false
    @Parameter(title: "账本") var ledger: BillingLedger?
    @Parameter(title: "分类") var category: BillingCategory?
    @Parameter(title: "金额") var amount: String?
    @Parameter(title: "时间") var date: Date?
    @Parameter(title: "备注") var note: String?
    @Parameter(title: "商户（分类线索，可选）", inputConnectionBehavior: .never) var merchant: String?
    @Parameter(title: "原始全文（分类线索，可选）", inputConnectionBehavior: .never) var ruleText: String?
    @Parameter(title: "账户") var account: BillingAccount?
    @Parameter(title: "标签") var tags: [BillingTag]?
    @Parameter(title: "附带图片", inputConnectionBehavior: .never) var attachment: IntentFile?
    @Parameter(title: "系统询问输入模板模式", default: false) var templateMode: Bool
    @Parameter(title: "菜单", inputConnectionBehavior: .never) var choice: String?
    @Parameter(title: "输入", default: "", inputConnectionBehavior: .never) var textValue: String
    static var parameterSummary: some ParameterSummary {
        Summary("自定义收入账单") { \.$ledger; \.$category; \.$amount; \.$date; \.$note; \.$merchant; \.$ruleText; \.$account; \.$tags; \.$attachment; \.$templateMode }
    }
    @MainActor func perform() async throws -> some IntentResult & ReturnsValue<String> & ProvidesDialog & OpensIntent {
        let draft = try await CustomBilling.draft(type: "income", ledger: ledger, category: category, amount: amount, date: date, note: note, account: account, destination: nil, tags: tags, excluded: false, merchant: merchant, ruleText: ruleText)
        if templateMode { return BillingHandoff.plain(try BillingStepFlow.start(draft), dialog: IntentDialog("")) }
        let state = try BillingStepFlow.start(draft)
        return try await BillingHandoff.start(state, attachment: attachment, choose: { values, prompt in
            try await $choice.requestDisambiguation(among: values, dialog: IntentDialog(stringLiteral: prompt))
        })
    }
}


@available(iOS 16.0, *)
struct CustomTransferBillingIntent: AppIntent {
    // Manual preset action: no AI, always review before committing.
    static var isDiscoverable: Bool = true
    static var title: LocalizedStringResource = "自定义转账账单"
    static var description: LocalizedStringResource = "手动填写字段或接入快捷指令变量，不调用 AI；运行后弹出账单确认菜单，可修改，确认后直接入账。"
    static var openAppWhenRun = false
    @Parameter(title: "账本") var ledger: BillingLedger?
    @Parameter(title: "金额") var amount: String?
    @Parameter(title: "时间") var date: Date?
    @Parameter(title: "备注") var note: String?
    @Parameter(title: "转出账户") var account: BillingAccount?
    @Parameter(title: "转入账户") var destination: BillingAccount?
    @Parameter(title: "标签") var tags: [BillingTag]?
    @Parameter(title: "附带图片", inputConnectionBehavior: .never) var attachment: IntentFile?
    @Parameter(title: "系统询问输入模板模式", default: false) var templateMode: Bool
    @Parameter(title: "菜单", inputConnectionBehavior: .never) var choice: String?
    @Parameter(title: "输入", default: "", inputConnectionBehavior: .never) var textValue: String
    static var parameterSummary: some ParameterSummary {
        Summary("自定义转账账单") { \.$ledger; \.$amount; \.$date; \.$note; \.$account; \.$destination; \.$tags; \.$attachment; \.$templateMode }
    }
    @MainActor func perform() async throws -> some IntentResult & ReturnsValue<String> & ProvidesDialog & OpensIntent {
        let draft = try await CustomBilling.draft(type: "transfer", ledger: ledger, category: nil, amount: amount, date: date, note: note, account: account, destination: destination, tags: tags, excluded: false)
        if templateMode { return BillingHandoff.plain(try BillingStepFlow.start(draft), dialog: IntentDialog("")) }
        let state = try BillingStepFlow.start(draft)
        return try await BillingHandoff.start(state, attachment: attachment, choose: { values, prompt in
            try await $choice.requestDisambiguation(among: values, dialog: IntentDialog(stringLiteral: prompt))
        })
    }
}

@available(iOS 16.0, *)
struct RecognizeConfirmBillingIntent: AppIntent {
    // Kept for existing shortcuts; use the image/text recognition actions.
    static var isDiscoverable: Bool = false
    static var title: LocalizedStringResource = "识别并确认记账"
    static var description: LocalizedStringResource = "图片或本地 OCR 识别，系统菜单编辑和拆分，最终一次确认直接入账。"
    static var openAppWhenRun = false
    @Parameter(title: "图片") var image: IntentFile
    @Parameter(title: "使用本地 OCR 后文字 AI（留空跟随 App）") var useOCR: Bool?
    @Parameter(title: "标签（留空跟随 App）") var tags: [BillingTag]?
    @Parameter(title: "清空标签", default: false) var clearTags: Bool
    @Parameter(title: "不计预算（留空跟随 App）") var excluded: Bool?
    @Parameter(title: "默认配置 JSON") var configuration: String?
    @Parameter(title: "菜单", inputConnectionBehavior: .never) var choice: String?
    static var parameterSummary: some ParameterSummary {
        Summary("识别\(\.$image)并确认记账") { \.$useOCR; \.$tags; \.$clearTags; \.$excluded }
    }
    @MainActor func recognitionConfiguration() throws -> [String: Any] {
        var config = try configuration.map(ConfirmedBilling.decode) ?? [:]
        if clearTags { config["tagIds"] = [Int]() }
        else if let tags { config["tagIds"] = Array(Set(tags.map { $0.id })).sorted() }
        if let excluded { config["excludeFromBudget"] = excluded }
        return config
    }
    @MainActor func perform() async throws -> some IntentResult & ReturnsValue<String> & ProvidesDialog {
        let config = try recognitionConfiguration()
        let effectiveConfiguration = try ConfirmedBilling.encode(config)
        let options = try await ConfirmedBilling.call(config.merging(["operation": "options"]) { _, new in new })
        let defaults = options["defaults"] as? [String: Any] ?? [:]
        let ocr = useOCR ?? ((config["mode"] as? String ?? defaults["mode"] as? String ?? "image") == "text")
        var draft: [String: Any]
        do { draft = try await ConfirmedBilling.recognizeImage(image, ocr: ocr, configuration: effectiveConfiguration) }
        catch {
            let detail = (error as? ShortcutBillingError)?.message ?? "请检查图片格式和 AI 配置"
            if try await $choice.requestDisambiguation(among: ["人工填写", "取消"], dialog: IntentDialog(stringLiteral: "识别未完成，未入账。" + detail + "。不会自动上传原图。")) == "取消" { throw error }
            let defaults = config
            let options = try await ConfirmedBilling.call(defaults.merging(["operation": "options"]) { _, new in new })
            let appDefaults = options["defaults"] as? [String: Any] ?? [:]
            var manual = appDefaults.merging(defaults) { _, explicit in explicit }
            manual.removeValue(forKey: "accountId")
            draft = ["status": "draft", "requestId": UUID().uuidString, "ledgerId": options["ledgerId"]!, "currency": options["currency"]!, "candidates": [manual]]
        }
        var editor = EditBillingDraftIntent()
        editor.draft = try ConfirmedBilling.encode(draft)
        let edited = try await editor.runEditor()
        let result = try await ConfirmedBilling.commit(ConfirmedBilling.decode(edited))
        let object = try ConfirmedBilling.decode(result)
        let count = object["count"] as? Int ?? 0
        let totalAmountMinor = object["totalAmountMinor"] as? Int ?? 0
        let minorDigits = object["minorDigits"] as? Int ?? 2
        let total = ConfirmedBilling.money(totalAmountMinor, digits: minorDigits)
        let currency = object["currency"] as? String ?? "CNY"
        let message = "已入账 \(count) 条，合计 \(total) \(currency)。云端尚未确认，请查看 App 同步状态，无需重记。"
        return .result(value: result, dialog: IntentDialog(stringLiteral: message))
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
                    templateMode: Bool = false,
                    independentInput: Bool = false,
                    showIncompleteDraft: Bool = false,
                    singleOnly: Bool = false,
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
        if templateMode { return try BillingStepFlow.start(ConfirmedBilling.encode(draft), showIncompleteDraft: showIncompleteDraft, singleOnly: singleOnly) }
        if independentInput { return try BillingStepFlow.start(ConfirmedBilling.encode(draft), showIncompleteDraft: showIncompleteDraft) }
        let editor = ConfirmedBillingEditor(draft: try ConfirmedBilling.encode(draft), choose: choose, input: input, showIncompleteDraft: showIncompleteDraft, call: call)
        // Cancellation exits before commit. Existing atomic/idempotent store is reused.
        let submission = try await editor.runEditor()
        return try await commit(ConfirmedBilling.decode(submission), attachment)
    }
}

@available(iOS 16.0, *)
struct ImageConfirmBillingIntent: AppIntent {
    static var title: LocalizedStringResource = "图片记账"
    static var description: LocalizedStringResource = "将图片交给 App 内 AI 判断收支、识别金额和账户；按分类规则预填，核对、编辑或拆分后一次确认入账。"
    static var openAppWhenRun = false
    @Parameter(title: "图片") var image: IntentFile
    @Parameter(title: "账本（留空使用当前账本）") var ledger: BillingLedger?
    @Parameter(title: "标签（留空跟随 App）") var tags: [BillingTag]?
    @Parameter(title: "清空标签", default: false) var clearTags: Bool
    @Parameter(title: "不计预算（仅支出，留空跟随 App）") var excluded: Bool?
    @Parameter(title: "附带图片", inputConnectionBehavior: .never) var attachment: IntentFile?
    @Parameter(title: "系统询问输入模板模式", default: false) var templateMode: Bool
    @Parameter(title: "菜单", inputConnectionBehavior: .never) var choice: String?
    @Parameter(title: "输入", default: "", inputConnectionBehavior: .never) var textValue: String
    static var parameterSummary: some ParameterSummary {
        Summary("识别\(\.$image)并确认记账") { \.$ledger; \.$tags; \.$clearTags; \.$excluded; \.$attachment; \.$templateMode }
    }
    @MainActor func perform() async throws -> some IntentResult & ReturnsValue<String> & ProvidesDialog & OpensIntent {
        let config = RecognitionBillingFlow.configuration(ledger: ledger, tags: tags, clearTags: clearTags, excluded: excluded)
        let saved = try await RecognitionBillingFlow.run(image: image, configuration: config, attachment: attachment, templateMode: templateMode, independentInput: !templateMode, choose: { values, prompt in
            try await $choice.requestDisambiguation(among: values, dialog: IntentDialog(stringLiteral: prompt))
        }, input: { _ in throw ShortcutBillingError(message: "普通入口必须交给独立系统输入") })
        if templateMode { return BillingHandoff.plain(saved, dialog: IntentDialog("")) }
        return try await BillingHandoff.start(saved, attachment: attachment, choose: { values, prompt in
            try await $choice.requestDisambiguation(among: values, dialog: IntentDialog(stringLiteral: prompt))
        })
    }
}


// Ordinary text billing is always interactive. A legacy preset must never turn
// it into a draft-only action with an empty result dialog. Template clients use
// their own hidden start action below, not a switch on the public entry.
@available(iOS 16.0, *)
@MainActor
enum TextBillingEntry {
    static func source(_ text: String?) -> String {
        (text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func run(text: String, configuration: [String: Any],
                    attachment: IntentFile? = nil, legacyTemplateMode: Bool = false, independentInput: Bool = false,
                    choose: @escaping ([String], String) async throws -> String,
                    input: @escaping (String) async throws -> String,
                    call: @escaping ([String: Any]) async throws -> [String: Any] = ConfirmedBilling.call,
                    commit: ([String: Any], IntentFile?) async throws -> String = { try await ConfirmedBilling.commit($0, attachment: $1) }) async throws -> String {
        let text = source(text)
        guard !text.isEmpty else { throw ShortcutBillingError(message: "没有收到记账文字，未入账") }
        // legacyTemplateMode is retained only to decode existing saved actions.
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
            attachment: attachment, templateMode: false, independentInput: independentInput, showIncompleteDraft: true,
            choose: choose, input: input, call: visibleCall, commit: commit)
    }
}

@available(iOS 16.0, *)
struct TextBillingTemplateStartIntent: AppIntent {
    static var isDiscoverable: Bool = false
    static var title: LocalizedStringResource = "文字记账草稿（模板专用）"
    static var description: LocalizedStringResource = "仅供完整系统输入模板调用，不是普通文字记账入口。"
    static var openAppWhenRun = false
    @Parameter(title: "文字") var text: String
    @Parameter(title: "账本（留空使用当前账本）") var ledger: BillingLedger?
    @Parameter(title: "标签（留空跟随 App）") var tags: [BillingTag]?
    @Parameter(title: "清空标签", default: false) var clearTags: Bool
    @Parameter(title: "不计预算（仅支出，留空跟随 App）") var excluded: Bool?
    @Parameter(title: "菜单", inputConnectionBehavior: .never) var choice: String?
    static var parameterSummary: some ParameterSummary {
        Summary("为系统输入模板识别\(\.$text)") { \.$ledger; \.$tags; \.$clearTags; \.$excluded }
    }
    @MainActor func perform() async throws -> some IntentResult & ReturnsValue<String> {
        let config = RecognitionBillingFlow.configuration(ledger: ledger, tags: tags, clearTags: clearTags, excluded: excluded)
        let state = try await RecognitionBillingFlow.run(text: text, configuration: config, templateMode: true, choose: { values, prompt in
            try await $choice.requestDisambiguation(among: values, dialog: IntentDialog(stringLiteral: prompt))
        }, input: { _ in throw ShortcutBillingError(message: "模板必须使用系统询问输入") })
        return .result(value: state)
    }
}

@available(iOS 16.0, *)
struct TextConfirmBillingIntent: AppIntent {
    static var title: LocalizedStringResource = "文字记账"
    static var description: LocalizedStringResource = "接收文字或截图 OCR 文本，调用 App 内文字 AI 自动识别，弹窗编辑和拆分，确认后直接入账。"
    static var openAppWhenRun = false
    @Parameter(title: "文字", requestValueDialog: "请输入记账文字，或连接截图提取的文本") var text: String?
    @Parameter(title: "账本（留空使用当前账本）") var ledger: BillingLedger?
    @Parameter(title: "标签（留空跟随 App）") var tags: [BillingTag]?
    @Parameter(title: "清空标签", default: false) var clearTags: Bool
    @Parameter(title: "不计预算（仅支出，留空跟随 App）") var excluded: Bool?
    @Parameter(title: "附带图片", inputConnectionBehavior: .never) var attachment: IntentFile?
    @Parameter(title: "系统询问输入模板模式", default: false) var templateMode: Bool
    @Parameter(title: "菜单", inputConnectionBehavior: .never) var choice: String?
    @Parameter(title: "输入", default: "", inputConnectionBehavior: .never) var textValue: String
    static var parameterSummary: some ParameterSummary {
        Summary("识别\(\.$text)并确认记账") { \.$ledger; \.$tags; \.$clearTags; \.$excluded; \.$attachment }
    }
    @MainActor func perform() async throws -> some IntentResult & ReturnsValue<String> & ProvidesDialog & OpensIntent {
        let source = TextBillingEntry.source(text)
        guard !source.isEmpty else {
            throw $text.needsValueError("请输入记账文字，或连接截图提取的文本")
        }
        let config = RecognitionBillingFlow.configuration(ledger: ledger, tags: tags, clearTags: clearTags, excluded: excluded)
        let saved = try await TextBillingEntry.run(text: source, configuration: config, attachment: attachment, legacyTemplateMode: templateMode, independentInput: true, choose: { values, prompt in
            try await $choice.requestDisambiguation(among: values, dialog: IntentDialog(stringLiteral: prompt))
        }, input: { _ in throw ShortcutBillingError(message: "普通入口必须交给独立系统输入") })
        return try await BillingHandoff.start(saved, attachment: attachment, choose: { values, prompt in
            try await $choice.requestDisambiguation(among: values, dialog: IntentDialog(stringLiteral: prompt))
        })
    }
}


// MARK: - Isolated runtime-prefill probe (no AI, bridge or bill persistence)

/// Only the current perform() owns this sample state. A new run starts fresh.
/// Kept separate so mocked state tests cannot be mistaken for system-UI tests.
struct ShortcutInputPrefillProbeState {
    var note = "广东电网｜生活缴费"
    var amount = 12.34

    var amountText: String {
        String(format: "%.2f", locale: Locale(identifier: "en_US_POSIX"), amount)
    }
    var menuItems: [String] {
        ["备注：" + (note.isEmpty ? "（空）" : note),
         "金额：" + amountText, "结束测试（不保存）"]
    }
    var summary: String {
        "测试结束，未记账。\n备注：" + (note.isEmpty ? "（空）" : note) + "\n金额：" + amountText
    }
}

@available(iOS 16.0, *)
@MainActor
enum ShortcutInputPrefillProbe {
    static func run(choose: ([String], String) async throws -> String,
                    editNote: (String) async throws -> String,
                    editAmount: (Double) async throws -> Double) async throws -> ShortcutInputPrefillProbeState {
        var state = ShortcutInputPrefillProbeState()
        while true {
            let items = state.menuItems
            let selected = try await choose(items, "输入预填测试（示例数据，不记账）")
            switch items.firstIndex(of: selected) {
            case 0:
                // Preserve an intentionally empty note; do not fall back to the sample.
                state.note = try await editNote(state.note)
            case 1:
                state.amount = try await editAmount(state.amount)
            case 2:
                return state
            default:
                throw ShortcutBillingError(message: "测试选项已失效，请重新运行；未记账")
            }
        }
    }
}

@available(iOS 16.0, *)
struct ShortcutInputPrefillProbeIntent: AppIntent {
    static var isDiscoverable = true
    static var title: LocalizedStringResource = "输入预填测试（不记账）"
    static var description: LocalizedStringResource = "只用固定示例测试运行菜单中的备注和金额预填、连续编辑及取消；不调用 AI、不读写账单、不打开 App。"
    static var openAppWhenRun = false

    // Optional slots prevent required-parameter resolution before perform().
    // .never prevents a preceding Shortcut action from supplying test values.
    @Parameter(title: "测试备注", inputOptions: String.IntentInputOptions(multiline: true), inputConnectionBehavior: .never)
    var editingNote: String?
    @Parameter(title: "测试金额", inputConnectionBehavior: .never)
    var editingAmount: Double?
    @Parameter(title: "测试菜单", inputConnectionBehavior: .never)
    var choice: String?

    static var parameterSummary: some ParameterSummary {
        Summary("测试备注和金额的运行时预填（不记账）")
    }

    private static func trace(_ event: String) {
        // Fixed stage labels only; never record note text or amount values.
        NSLog("[ShortcutPrefillProbe] %@", event)
    }

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<String> & ProvidesDialog {
        Self.trace("perform.started")
        do {
            let state = try await ShortcutInputPrefillProbe.run(choose: { items, prompt in
                choice = nil
                Self.trace("menu.requested")
                let selected = try await $choice.requestDisambiguation(among: items, dialog: IntentDialog(stringLiteral: prompt))
                Self.trace("menu.returned")
                return selected
            }, editNote: { current in
                // This assignment is the experiment: does the host display the
                // current wrappedValue as editable text when explicitly asked?
                editingNote = current
                Self.trace("note.requested")
                let edited = try await $editingNote.requestValue("修改备注（测试）：请观察输入框是否带有原文")
                Self.trace("note.returned")
                return edited
            }, editAmount: { current in
                editingAmount = current
                Self.trace("amount.requested")
                let edited = try await $editingAmount.requestValue("修改金额（测试）：请观察输入框是否带有原金额")
                Self.trace("amount.returned")
                return edited
            })
            Self.trace("perform.finished")
            return .result(value: state.summary, dialog: IntentDialog(stringLiteral: state.summary))
        } catch {
            Self.trace(error is CancellationError ? "perform.cancelled" : "perform.error code=" + String((error as NSError).code))
            // Do not translate an AppIntent error or restart perform(); both can
            // change the very system behavior this isolated probe is testing.
            throw error
        }
    }
}


// MARK: - Two-action AI -> Shortcuts-variable prefill probe (never commits)

/// A per-invocation value, not a saved bill or a queryable global draft.
/// @Property exposes scalar fields to Shortcuts' Magic Variable picker.
@available(iOS 16.0, *)
struct ShortcutAIDraftProbeEntity: TransientAppEntity {
    static var typeDisplayRepresentation: TypeDisplayRepresentation = "AI 测试草稿"
    var id = UUID()
    @Property(title: "备注") var note: String
    @Property(title: "金额") var amount: Double
    @Property(title: "币种") var currency: String
    @Property(title: "小数位数") var minorDigits: Int
    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "AI 测试草稿（未保存）")
    }
    init() {
        note = ""; amount = 0; currency = ""; minorDigits = 2
    }
    init(note: String, amount: Double, currency: String, minorDigits: Int) {
        self.init()
        self.note = note; self.amount = amount
        self.currency = currency; self.minorDigits = minorDigits
    }
}

@available(iOS 16.0, *)
struct ShortcutAIPrefillProbeState {
    var note: String
    var amount: Double
    let currency: String
    let minorDigits: Int
    var amountText: String {
        String(format: "%.*f", locale: Locale(identifier: "en_US_POSIX"), minorDigits, amount)
    }
    var menuItems: [String] {
        ["备注：" + (note.isEmpty ? "（空）" : note),
         "金额：" + amountText + " " + currency, "结束测试（不保存）"]
    }
    var summary: String {
        "AI 草稿预填测试结束，未保存账单。\n备注：" + (note.isEmpty ? "（空）" : note) + "\n金额：" + amountText + " " + currency
    }
}

@available(iOS 16.0, *)
@MainActor
enum ShortcutAIPrefillProbe {
    static func entity(from draft: [String: Any]) throws -> ShortcutAIDraftProbeEntity {
        guard draft["status"] as? String == "draft",
              let candidates = draft["candidates"] as? [[String: Any]], !candidates.isEmpty else {
            throw ShortcutBillingError(message: "AI 未返回有效草稿；未保存账单")
        }
        guard candidates.count == 1 else {
            throw ShortcutBillingError(message: "本次预填测试仅支持单笔，AI 识别出多笔；未取首笔，也未保存账单")
        }
        let candidate = candidates[0]
        let options = draft["options"] as? [String: Any] ?? [:]
        guard candidate["blocked"] as? Bool != true,
              let currency = draft["currency"] as? String, !currency.isEmpty,
              let digits = options["minorDigits"] as? Int, (0...4).contains(digits),
              let minor = candidate["amountMinor"] as? Int, minor > 0, minor <= 999999999999,
              let note = candidate["note"] as? String, note.count <= 10000 else {
            throw ShortcutBillingError(message: "金额、备注或币种无效，请核对识别结果；未保存账单")
        }
        let scale = Double([1, 10, 100, 1000, 10000][digits])
        return ShortcutAIDraftProbeEntity(note: note, amount: Double(minor) / scale, currency: currency, minorDigits: digits)
    }

    static func recognize(image: IntentFile?, text: String?, ledger: BillingLedger?,
                          call: ([String: Any]) async throws -> [String: Any] = ConfirmedBilling.call,
                          recognizeImage: (IntentFile, String) async throws -> [String: Any] = {
                              try await ConfirmedBilling.recognizeImage($0, ocr: false, configuration: $1)
                          }) async throws -> ShortcutAIDraftProbeEntity {
        let source = (text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard (image != nil) != !source.isEmpty else {
            throw ShortcutBillingError(message: "请只连接图片或文字其中一种输入；未保存账单")
        }
        var config: [String: Any] = [:]
        if let ledger { config["ledgerId"] = ledger.id }
        let options = try await call(config.merging(["operation": "options"]) { _, new in new })
        guard let ledgerId = options["ledgerId"] as? Int else {
            throw ShortcutBillingError(message: "当前账本无效，请先在 App 中选择账本；未保存账单")
        }
        config["ledgerId"] = ledgerId
        let draft: [String: Any]
        if let image {
            draft = try await recognizeImage(image, ConfirmedBilling.encode(config))
        } else {
            config["operation"] = "recognize"; config["mode"] = "text"; config["text"] = source
            config["timeZoneOffsetSeconds"] = TimeZone.current.secondsFromGMT()
            draft = try await call(config)
        }
        return try entity(from: draft)
    }

    static func checkedAmount(_ value: Double, digits: Int) throws -> Double {
        guard (0...4).contains(digits), value.isFinite, value > 0 else {
            throw ShortcutBillingError(message: "测试金额必须大于零；未保存账单")
        }
        let minor = value * Double([1, 10, 100, 1000, 10000][digits])
        guard minor <= 999999999999, abs(minor - minor.rounded()) < 0.001 else {
            throw ShortcutBillingError(message: "测试金额超出范围或小数位数，未保存账单")
        }
        return value
    }

    static func initialState(draft: ShortcutAIDraftProbeEntity, note: String?, amount: Double?) throws -> ShortcutAIPrefillProbeState {
        // An entity parameter alone is insufficient: these scalar slots must be
        // bound by Shortcuts BEFORE perform(), not assigned from draft here.
        guard (0...4).contains(draft.minorDigits), !draft.currency.isEmpty,
              let initialNote = note ?? (draft.note.isEmpty ? "" : nil),
              let initialAmount = amount else {
            throw ShortcutBillingError(message: "请将上一步草稿的备注、金额属性分别连接到此动作的备注、金额参数；未保存账单")
        }
        guard initialNote == draft.note, abs(initialAmount - draft.amount) < 0.00001 else {
            throw ShortcutBillingError(message: "备注或金额与草稿不一致，请选择同一草稿变量的对应属性；未保存账单")
        }
        return ShortcutAIPrefillProbeState(note: initialNote,
            amount: try checkedAmount(initialAmount, digits: draft.minorDigits),
            currency: draft.currency, minorDigits: draft.minorDigits)
    }

    static func run(initial: ShortcutAIPrefillProbeState,
                    choose: ([String], String) async throws -> String,
                    editNote: (String) async throws -> String,
                    editAmount: (Double) async throws -> Double) async throws -> ShortcutAIPrefillProbeState {
        var state = initial
        while true {
            let items = state.menuItems
            let selected = try await choose(items, "确认 AI 草稿（测试，不保存）")
            switch items.firstIndex(of: selected) {
            case 0: state.note = try await editNote(state.note)
            case 1: state.amount = try checkedAmount(await editAmount(state.amount), digits: state.minorDigits)
            case 2: return state
            default: throw ShortcutBillingError(message: "测试选项已失效；未保存账单")
            }
        }
    }
}

@available(iOS 16.0, *)
struct RecognizeAIDraftProbeIntent: AppIntent {
    static var isDiscoverable = true
    static var title: LocalizedStringResource = "AI识别草稿（测试，不记账）"
    static var description: LocalizedStringResource = "仅识别单笔图片或文字，使用 App 内配置的 AI，输出可通过变量选取的备注和金额；图片会发送给配置的视觉服务。本动作不保存账单。"
    static var openAppWhenRun = false
    @Parameter(title: "图片") var image: IntentFile?
    @Parameter(title: "文字") var text: String?
    @Parameter(title: "账本（留空使用当前账本）") var ledger: BillingLedger?
    static var parameterSummary: some ParameterSummary {
        Summary("AI 识别草稿（不记账）") { \.$image; \.$text; \.$ledger }
    }
    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<ShortcutAIDraftProbeEntity> {
        .result(value: try await ShortcutAIPrefillProbe.recognize(image: image, text: text, ledger: ledger))
    }
}

@available(iOS 16.0, *)
struct ConfirmAIDraftProbeIntent: AppIntent {
    static var isDiscoverable = true
    static var title: LocalizedStringResource = "确认AI草稿（测试，不保存）"
    static var description: LocalizedStringResource = "把同一个上一步 AI 草稿及其备注、金额属性分别连接到三个参数。菜单显示传入值，点字段测试原值及连续编辑。本动作不调用 AI、不保存账单。"
    static var openAppWhenRun = false
    @Parameter(title: "AI 草稿") var draft: ShortcutAIDraftProbeEntity
    @Parameter(title: "备注", inputOptions: String.IntentInputOptions(multiline: true), inputConnectionBehavior: .never) var note: String?
    @Parameter(title: "金额", inputConnectionBehavior: .never) var amount: Double?
    @Parameter(title: "测试菜单", inputConnectionBehavior: .never) var choice: String?
    static var parameterSummary: some ParameterSummary {
        Summary("确认 \(\.$draft)（不保存）") { \.$note; \.$amount }
    }
    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<String> & ProvidesDialog {
        let initial = try ShortcutAIPrefillProbe.initialState(draft: draft, note: note, amount: amount)
        let final = try await ShortcutAIPrefillProbe.run(initial: initial, choose: { items, prompt in
            choice = nil
            return try await $choice.requestDisambiguation(among: items, dialog: IntentDialog(stringLiteral: prompt))
        }, editNote: { current in
            // Keep the same declared, pre-bound slot for every edit. Do not nil it.
            note = current
            return try await $note.requestValue("修改备注：可在 AI 原文基础上增删")
        }, editAmount: { current in
            amount = current
            return try await $amount.requestValue("修改金额：请核对 AI 识别的原金额")
        })
        return .result(value: final.summary, dialog: IntentDialog(stringLiteral: final.summary))
    }
}


// MARK: - Round one: complete single bill + Shortcuts-owned system input

@available(iOS 16.0, *)
enum SingleBillingSource: String, AppEnum {
    case image, text, expense, income, transfer
    static var typeDisplayRepresentation: TypeDisplayRepresentation = "单笔来源"
    static var caseDisplayRepresentations: [SingleBillingSource: DisplayRepresentation] = [
        .image: "图片 AI", .text: "文字 AI", .expense: "手填支出", .income: "手填收入", .transfer: "手填转账"
    ]
}

/// Per-run state carried by a Shortcuts variable, not a saved/global bill.
/// The scalar fields feed SYSTEM Ask for Input, never requestValue.
@available(iOS 16.0, *)
struct SingleBillingStep: TransientAppEntity {
    static var typeDisplayRepresentation: TypeDisplayRepresentation = "单笔编辑步骤"
    var id = UUID()
    @Property(title: "完整状态") var state: String
    @Property(title: "步骤状态") var status: String
    @Property(title: "输入提示") var prompt: String
    @Property(title: "输入类型") var inputType: String
    @Property(title: "当前内容") var currentText: String
    @Property(title: "当前数字") var currentNumber: Double
    @Property(title: "当前时间") var currentDate: Date
    @Property(title: "结果说明") var resultMessage: String
    var displayRepresentation: DisplayRepresentation { DisplayRepresentation(title: "单笔编辑步骤") }
    init() {
        state = ""; status = ""; prompt = ""; inputType = ""; currentText = ""; currentNumber = 0
        currentDate = Date(timeIntervalSince1970: 0); resultMessage = ""
    }
    @MainActor init(_ envelope: String) throws {
        self.init()
        let object = try ConfirmedBilling.decode(envelope)
        guard let phase = object["status"] as? String, ["editing", "input", "confirmed", "cancelled", "split-confirmed", "split-retry", "split-next", "split-ended"].contains(phase) else {
            throw ShortcutBillingError(message: "单笔步骤格式无效，未入账")
        }
        state = envelope; status = phase
        resultMessage = object["message"] as? String ?? ""
        if phase == "input" {
            guard let request = object["input"] as? [String: Any],
                  let message = request["prompt"] as? String,
                  let value = request["currentValue"] as? String,
                  let kind = request["inputType"] as? String, ["text", "number", "date"].contains(kind) else {
                throw ShortcutBillingError(message: "单笔输入请求无效，未入账")
            }
            prompt = message; inputType = kind; currentText = value
            if kind == "number" { currentNumber = Double(value) ?? 0 }
            if kind == "date" {
                guard let date = SingleBillingFlow.date(value) else { throw ShortcutBillingError(message: "当前时间格式无效，未入账") }
                currentDate = date
            }
        }
    }
}

@available(iOS 16.0, *)
@MainActor
enum SingleBillingFlow {
    static func date(_ value: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractional.date(from: value) ?? ISO8601DateFormatter().date(from: value)
    }
    static func checkSingle(_ step: SingleBillingStep) throws {
        let outer = try ConfirmedBilling.decode(step.state)
        guard outer["status"] as? String == step.status else { throw ShortcutBillingError(message: "步骤状态不一致，未入账") }
        if let progressive = outer["splitContext"] as? [String: Any] { _ = try ProgressiveSplitFlow.context(progressive) }
        else if step.status.hasPrefix("split-") { throw ShortcutBillingError(message: "拆分会话缺失，请停止并查询已保存结果") }
        if ["editing", "input"].contains(step.status) {
            guard let raw = outer["state"] as? String else { throw ShortcutBillingError(message: "单笔状态缺失，未入账") }
            let state = try ConfirmedBilling.decode(raw)
            guard state["singleOnly"] as? Bool == true else { throw ShortcutBillingError(message: "请传入开始单笔记账的步骤，不能混用旧模板") }
        } else if step.status == "confirmed", outer["singleOnly"] as? Bool != true {
            throw ShortcutBillingError(message: "不是单笔确认结果，未入账")
        }
    }
    static func advance(_ step: SingleBillingStep, hasResponse: Bool, text: String?, number: Double?, date: Date?,
                        choose: @escaping ([String], String) async throws -> String,
                        call: @escaping ([String: Any]) async throws -> [String: Any] = ConfirmedBilling.call) async throws -> SingleBillingStep {
        try checkSingle(step)
        if ["split-next", "split-retry"].contains(step.status) {
            let next = try await ProgressiveSplitFlow.next(step, choose: choose)
            if next.status == "editing" { return try await advance(next, hasResponse: false, text: nil, number: nil, date: nil, choose: choose, call: call) }
            return next
        }
        if step.status == "split-ended" { return step }
        guard ["editing", "input"].contains(step.status) else { throw ShortcutBillingError(message: "此步骤已结束，请勿继续编辑") }
        var response = text
        if step.status == "input", hasResponse {
            let object = try ConfirmedBilling.decode(step.state)
            let kind = (object["input"] as? [String: Any])?["inputType"] as? String
            if kind == "number" {
                guard let number, number.isFinite else { throw ShortcutBillingError(message: "请把系统数字输入结果连接到数字结果") }
                // Currency precision/range is checked by the integer-money parser
                // in the editor. Do not silently round off an invalid input.
                guard let decimal = Decimal(string: String(number), locale: Locale(identifier: "en_US_POSIX")) else {
                    throw ShortcutBillingError(message: "数字格式无效，未入账")
                }
                response = NSDecimalNumber(decimal: decimal).stringValue
            } else if kind == "date" {
                guard let date else { throw ShortcutBillingError(message: "请把系统日期时间结果连接到日期结果") }
                response = ISO8601DateFormatter().string(from: date)
            }
        }
        let result = try await BillingStepFlow.advance(step.state, response: response, hasResponse: hasResponse, choose: choose, call: call)
        if (try ConfirmedBilling.decode(result))["status"] as? String == "split-start" {
            let part = try ProgressiveSplitFlow.begin(result)
            return try await advance(part, hasResponse: false, text: nil, number: nil, date: nil, choose: choose, call: call)
        }
        return try SingleBillingStep(result)
    }
    static func save(_ step: SingleBillingStep, attachment: IntentFile?,
                     commit: ([String: Any], IntentFile?) async throws -> String = { try await ConfirmedBilling.commit($0, attachment: $1) }) async throws -> String {
        try checkSingle(step)
        let outer = try ConfirmedBilling.decode(step.state)
        guard step.status == "confirmed", outer["splitContext"] == nil, let raw = outer["submission"] as? String else {
            throw ShortcutBillingError(message: "尚未最终确认，不可入账")
        }
        let submission = try ConfirmedBilling.decode(raw)
        guard submission["confirmed"] as? Bool == true,
              let entries = submission["entries"] as? [[String: Any]], entries.count == 1, submission["split"] == nil else {
            throw ShortcutBillingError(message: "单笔提交内容无效，未入账")
        }
        // Existing commit validates live references and deduplicates request IDs.
        return try await commit(submission, attachment)
    }
}

@available(iOS 16.0, *)
struct StartSingleBillingIntent: AppIntent {
    static var isDiscoverable = true
    static var title: LocalizedStringResource = "开始单笔记账（系统输入）"
    static var description: LocalizedStringResource = "图片/文字只识别一次，或手填预设。本动作只产生草稿；配合继续单笔确认、系统请求输入及最终保存。支出可进入逐笔拆分，需配合保存拆分当前笔。图片会发送给 App 配置的视觉服务。"
    static var openAppWhenRun = false
    @Parameter(title: "来源", default: .image) var source: SingleBillingSource
    @Parameter(title: "图片") var image: IntentFile?
    @Parameter(title: "文字", inputConnectionBehavior: .never) var text: String?
    @Parameter(title: "账本") var ledger: BillingLedger?
    @Parameter(title: "金额（手填模式）", inputConnectionBehavior: .never) var amount: String?
    @Parameter(title: "备注（手填模式）", inputConnectionBehavior: .never) var note: String?
    @Parameter(title: "商户（手填分类线索，可选）", inputConnectionBehavior: .never) var merchant: String?
    @Parameter(title: "原始全文（手填分类线索，可选）", inputConnectionBehavior: .never) var ruleText: String?
    @Parameter(title: "时间（手填模式）") var date: Date?
    @Parameter(title: "分类（手填模式）") var category: BillingCategory?
    @Parameter(title: "账户（手填模式）") var account: BillingAccount?
    @Parameter(title: "转入账户（手填转账）") var destination: BillingAccount?
    @Parameter(title: "标签（留空跟随 App）") var tags: [BillingTag]?
    @Parameter(title: "清空标签", default: false) var clearTags: Bool
    @Parameter(title: "不计预算（支出，留空跟随 App）") var excluded: Bool?
    @Parameter(title: "菜单", inputConnectionBehavior: .never) var choice: String?
    static var parameterSummary: some ParameterSummary {
        Summary("开始\(\.$source)单笔草稿") { \.$image; \.$text; \.$ledger; \.$amount; \.$note; \.$merchant; \.$ruleText; \.$date; \.$category; \.$account; \.$destination; \.$tags; \.$clearTags; \.$excluded }
    }
    @MainActor func perform() async throws -> some IntentResult & ReturnsValue<SingleBillingStep> {
        let config = RecognitionBillingFlow.configuration(ledger: ledger, tags: tags, clearTags: clearTags, excluded: excluded)
        let state: String
        if source == .image || source == .text {
            if source == .image && image == nil { throw ShortcutBillingError(message: "请连接图片；未入账") }
            let content = (text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            if source == .text && content.isEmpty { throw ShortcutBillingError(message: "请连接文字或 OCR 结果；未入账") }
            state = try await RecognitionBillingFlow.run(image: source == .image ? image : nil, text: source == .text ? content : nil,
                configuration: config, templateMode: true, showIncompleteDraft: true, singleOnly: true,
                choose: { values, prompt in try await $choice.requestDisambiguation(among: values, dialog: IntentDialog(stringLiteral: prompt)) },
                input: { _ in throw ShortcutBillingError(message: "请使用系统请求输入") })
        } else {
            let type = source == .income ? "income" : source == .transfer ? "transfer" : "expense"
            let options = try await ConfirmedBilling.call(config.merging(["operation": "options", "type": type]) { _, new in new })
            let defaults = options["defaults"] as? [String: Any] ?? [:]
            let effectiveTags = clearTags ? [BillingTag]() : tags
            let draft = try await CustomBilling.draft(type: type, ledger: ledger, category: category, amount: amount, date: date, note: note, account: account,
                destination: destination, tags: effectiveTags, excluded: excluded ?? (defaults["excludeFromBudget"] as? Bool ?? false), merchant: merchant, ruleText: ruleText)
            state = try BillingStepFlow.start(draft, showIncompleteDraft: true, singleOnly: true)
        }
        return .result(value: try SingleBillingStep(state))
    }
}

@available(iOS 16.0, *)
struct ContinueSingleBillingIntent: AppIntent {
    static var isDiscoverable = true
    static var title: LocalizedStringResource = "继续单笔确认（系统输入）"
    static var description: LocalizedStringResource = "显示完整单笔菜单。备注/金额/时间编辑返回输入请求，由快捷指令系统请求输入预填后继续；本动作不保存账单。"
    static var openAppWhenRun = false
    @Parameter(title: "上一步骤") var step: SingleBillingStep
    @Parameter(title: "已提供输入", default: false) var hasResponse: Bool
    @Parameter(title: "文字结果", inputConnectionBehavior: .never) var text: String?
    @Parameter(title: "数字结果", inputConnectionBehavior: .never) var number: Double?
    @Parameter(title: "日期结果", inputConnectionBehavior: .never) var date: Date?
    @Parameter(title: "菜单", inputConnectionBehavior: .never) var choice: String?
    static var parameterSummary: some ParameterSummary {
        Summary("继续单笔确认 \(\.$step)") { \.$hasResponse; \.$text; \.$number; \.$date }
    }
    @MainActor func perform() async throws -> some IntentResult & ReturnsValue<SingleBillingStep> {
        .result(value: try await SingleBillingFlow.advance(step, hasResponse: hasResponse, text: text, number: number, date: date,
            choose: { values, prompt in try await $choice.requestDisambiguation(among: values, dialog: IntentDialog(stringLiteral: prompt)) }))
    }
}

@available(iOS 16.0, *)
struct SaveSingleBillingIntent: AppIntent {
    static var isDiscoverable = true
    static var title: LocalizedStringResource = "保存已确认单笔账单"
    static var description: LocalizedStringResource = "仅接受单笔步骤中的最终确认结果，真实写入账单。相同请求重试去重；可连接原图作为附件。"
    static var openAppWhenRun = false
    @Parameter(title: "最终确认步骤") var step: SingleBillingStep
    @Parameter(title: "附带图片（可选）", inputConnectionBehavior: .never) var attachment: IntentFile?
    static var parameterSummary: some ParameterSummary { Summary("保存已确认单笔 \(\.$step)") { \.$attachment } }
    @MainActor func perform() async throws -> some IntentResult & ReturnsValue<String> & ProvidesDialog {
        let saved = try await SingleBillingFlow.save(step, attachment: attachment)
        return .result(value: saved, dialog: try CustomBilling.result(saved))
    }
}


// MARK: - Progressive expense split: each confirmation commits one bill

@available(iOS 16.0, *)
@MainActor
enum ProgressiveSplitFlow {
    static func context(_ value: [String: Any]) throws -> [String: Any] {
        guard value["version"] as? Int == 1,
              let session = value["sessionId"] as? String, UUID(uuidString: session) != nil,
              let total = value["totalMinor"] as? Int, total > 0, total <= 999999999999,
              let paid = value["paidMinor"] as? Int, paid >= 0, paid <= total,
              let count = value["savedCount"] as? Int, count >= 0, count <= 100,
              let digits = value["minorDigits"] as? Int, (0...4).contains(digits),
              let ledger = value["ledgerId"] as? Int, ledger > 0,
              let account = value["accountId"] as? Int, account > 0,
              let currency = value["currency"] as? String, currency.count == 3,
              value["template"] is [String: Any] else {
            throw ShortcutBillingError(message: "拆分进度无效，请停止并查询已保存账单，不要重新记入原总额")
        }
        return value
    }
    static func summary(_ value: [String: Any]) throws -> String {
        let value = try context(value)
        let total = value["totalMinor"] as! Int
        let paid = value["paidMinor"] as! Int
        let digits = value["minorDigits"] as! Int
        return "逐笔拆分 · 原总额 " + ConfirmedBilling.money(total, digits: digits) + " " + (value["currency"] as! String) +
            "\n已记 " + String(value["savedCount"] as! Int) + " 笔 / " + ConfirmedBilling.money(paid, digits: digits) +
            " · 剩余未记 " + ConfirmedBilling.money(total - paid, digits: digits)
    }
    static func envelope(_ phase: String, context: [String: Any], submission: String? = nil, message: String? = nil) throws -> SingleBillingStep {
        var result: [String: Any] = ["status": phase, "singleOnly": true, "splitContext": try self.context(context)]
        if let submission { result["submission"] = submission }
        if let message { result["message"] = message }
        return try SingleBillingStep(ConfirmedBilling.encode(result))
    }
    static func cancelled(_ value: [String: Any]?) throws -> String {
        guard let value else { return try ConfirmedBilling.encode(["status": "cancelled"]) }
        return try envelope("split-ended", context: value,
            message: summary(value) + "\n已放弃当前未保存笔，已保存账单保留；剩余金额不自动入账。云端同步请查看 App。").state
    }
    static func partID(_ session: String, index: Int) -> String {
        // Stable per-session/slot ID, including retries of an older state.
        let hash = Array(SHA256.hash(data: Data((session.lowercased() + "/part/" + String(index)).utf8)))
        var bytes = Array(hash.prefix(16))
        bytes[6] = (bytes[6] & 0x0f) | 0x50
        bytes[8] = (bytes[8] & 0x3f) | 0x80
        let hex = bytes.map { String(format: "%02x", $0) }.joined()
        let indexes = [8, 12, 16, 20]
        var result = ""
        for (index, char) in hex.enumerated() {
            if indexes.contains(index) { result += "-" }
            result.append(char)
        }
        return result
    }
    static func begin(_ start: String) throws -> SingleBillingStep {
        let outer = try ConfirmedBilling.decode(start)
        guard outer["status"] as? String == "split-start", let raw = outer["submission"] as? String else {
            throw ShortcutBillingError(message: "请从当前未保存的支出草稿进入拆分")
        }
        let bill = try ConfirmedBilling.decode(raw)
        guard bill["progressiveSplitStart"] as? Bool == true, bill["confirmed"] as? Bool == false,
              bill["type"] as? String == "expense", let session = bill["requestId"] as? String,
              let entries = bill["entries"] as? [[String: Any]], entries.count == 1,
              let date = bill["occurredAt"] as? String else {
            throw ShortcutBillingError(message: "拆分起点无效，原账单未保存")
        }
        var initial = entries[0]
        initial["occurredAt"] = date
        let ctx: [String: Any] = ["version": 1, "sessionId": session.lowercased(),
            "totalMinor": bill["originalAmountMinor"] ?? 0, "paidMinor": 0, "savedCount": 0,
            "ledgerId": bill["ledgerId"] ?? 0, "accountId": bill["accountId"] ?? 0,
            "currency": bill["currency"] ?? "", "minorDigits": bill["minorDigits"] ?? -1,
            "template": initial, "useAllRemaining": false]
        return try part(ctx, useAll: false)
    }
    static func part(_ value: [String: Any], useAll: Bool) throws -> SingleBillingStep {
        var value = try context(value)
        let remaining = (value["totalMinor"] as! Int) - (value["paidMinor"] as! Int)
        let count = value["savedCount"] as! Int
        guard remaining > 0, count < 100 else { throw ShortcutBillingError(message: "余额为零或达到 100 笔上限，不能新增") }
        value["useAllRemaining"] = useAll
        var candidate = value["template"] as! [String: Any]
        candidate["type"] = "expense"; candidate["amountMinor"] = remaining
        candidate["accountId"] = value["accountId"]
        let draft: [String: Any] = ["status": "draft", "requestId": partID(value["sessionId"] as! String, index: count + 1),
            "ledgerId": value["ledgerId"]!, "currency": value["currency"]!, "candidates": [candidate]]
        let state = try BillingStepFlow.start(ConfirmedBilling.encode(draft), showIncompleteDraft: true, singleOnly: true)
        var outer = try ConfirmedBilling.decode(state)
        outer["splitContext"] = value
        return try SingleBillingStep(ConfirmedBilling.encode(outer))
    }
    static func next(_ step: SingleBillingStep,
                     choose: ([String], String) async throws -> String) async throws -> SingleBillingStep {
        let outer = try ConfirmedBilling.decode(step.state)
        let ctx = try context(outer["splitContext"] as? [String: Any] ?? [:])
        do {
            if step.status == "split-retry" {
                let selected = try await choose(["重试保存当前笔", "结束并稍后查询"],
                    (outer["message"] as? String ?? "当前笔结果待确认") + "\n重试保持同一请求，不会另起一笔。")
                guard let raw = outer["submission"] as? String else { throw ShortcutBillingError(message: "待查请求丢失，请在 App 查询，勿重记") }
                if selected == "重试保存当前笔" { return try envelope("split-confirmed", context: ctx, submission: raw) }
                let bill = try ConfirmedBilling.decode(raw)
                return try envelope("split-ended", context: ctx, submission: raw,
                    message: summary(ctx) + "\n当前笔结果尚未确认；它可能已经保存。请求 ID：" + (bill["requestId"] as? String ?? "") +
                    "\n已知已保存账单不撤销。请查询此请求，勿重新开始记入原总额。")
            }
            guard step.status == "split-next" else { throw ShortcutBillingError(message: "此步骤不能新增拆分") }
            let selected = try await choose(["继续拆下一笔", "剩余作为最后一笔编辑", "结束拆分"],
                summary(ctx) + "\n上一笔已在本机保存；云端同步请看 App。结束不会补记余额。")
            if selected == "继续拆下一笔" { return try part(ctx, useAll: false) }
            if selected == "剩余作为最后一笔编辑" { return try part(ctx, useAll: true) }
            return try envelope("split-ended", context: ctx,
                message: summary(ctx) + "\n已结束，已保存账单保留，剩余金额未入账。")
        } catch is CancellationError {
            if step.status == "split-retry" {
                return try envelope("split-ended", context: ctx, submission: outer["submission"] as? String,
                    message: summary(ctx) + "\n当前笔结果可能尚未确认，请查询原请求；不要重记。")
            }
            return try SingleBillingStep(cancelled(ctx))
        }
    }
    static func checkedSubmission(_ outer: [String: Any], context ctx: [String: Any]) throws -> [String: Any] {
        guard let raw = outer["submission"] as? String else { throw ShortcutBillingError(message: "缺少当前笔确认内容") }
        let bill = try ConfirmedBilling.decode(raw)
        let index = (ctx["savedCount"] as! Int) + 1
        let remaining = (ctx["totalMinor"] as! Int) - (ctx["paidMinor"] as! Int)
        guard bill["confirmed"] as? Bool == true, bill["type"] as? String == "expense",
              bill["requestId"] as? String == partID(ctx["sessionId"] as! String, index: index),
              bill["ledgerId"] as? Int == ctx["ledgerId"] as? Int,
              bill["accountId"] as? Int == ctx["accountId"] as? Int,
              bill["currency"] as? String == ctx["currency"] as? String,
              let split = bill["split"] as? [String: Any], split["sessionId"] as? String == ctx["sessionId"] as? String,
              split["totalMinor"] as? Int == ctx["totalMinor"] as? Int, split["partIndex"] as? Int == index,
              let entries = bill["entries"] as? [[String: Any]], entries.count == 1,
              let amount = entries[0]["amountMinor"] as? Int, amount > 0, amount <= remaining,
              bill["originalAmountMinor"] as? Int == amount,
              ctx["useAllRemaining"] as? Bool != true || amount == remaining else {
            throw ShortcutBillingError(message: "当前笔与拆分进度不符，不提交；请查询已保存结果")
        }
        return bill
    }
    static func applied(_ receipt: [String: Any], bill: [String: Any], context initial: [String: Any]) throws -> SingleBillingStep {
        var ctx = try context(initial)
        let amount = bill["originalAmountMinor"] as! Int
        let expectedCount = (ctx["savedCount"] as! Int) + 1
        let expectedPaid = (ctx["paidMinor"] as! Int) + amount
        let total = ctx["totalMinor"] as! Int
        guard receipt["status"] as? String == "committed", receipt["requestId"] as? String == bill["requestId"] as? String,
              receipt["count"] as? Int == 1, receipt["type"] as? String == "expense",
              receipt["totalAmountMinor"] as? Int == amount, receipt["currency"] as? String == ctx["currency"] as? String,
              let split = receipt["split"] as? [String: Any], split["sessionId"] as? String == ctx["sessionId"] as? String,
              split["partIndex"] as? Int == expectedCount, split["savedCount"] as? Int == expectedCount,
              split["totalMinor"] as? Int == total, split["paidMinor"] as? Int == expectedPaid,
              split["remainingMinor"] as? Int == total - expectedPaid else {
            throw ShortcutBillingError(message: "保存回执与当前笔不一致，余额未推进，请查询原请求")
        }
        ctx["paidMinor"] = expectedPaid; ctx["savedCount"] = expectedCount
        var last = ((bill["entries"] as? [[String: Any]]) ?? [[:]])[0]
        last["occurredAt"] = bill["occurredAt"]
        ctx["template"] = last
        let end = expectedPaid == total || expectedCount == 100
        return try envelope(end ? "split-ended" : "split-next", context: ctx,
            message: summary(ctx) + (expectedPaid == total ? "\n全部拆分已在本机入账。" : expectedCount == 100 ? "\n已达 100 笔上限，剩余未记，不自动保存。" : "\n当前笔已保存，可继续或结束。") + "云端同步请查看 App。")
    }
    static func save(_ step: SingleBillingStep, attachment: IntentFile?,
                     call: ([String: Any]) async throws -> [String: Any] = ConfirmedBilling.call) async throws -> SingleBillingStep {
        try SingleBillingFlow.checkSingle(step)
        guard step.status == "split-confirmed" else { throw ShortcutBillingError(message: "请先确认当前拆分笔，未提交") }
        let outer = try ConfirmedBilling.decode(step.state)
        let ctx = try context(outer["splitContext"] as? [String: Any] ?? [:])
        let bill = try checkedSubmission(outer, context: ctx)
        var retryRaw = outer["submission"] as! String
        var payload = bill
        var attemptedPayload = false
        do {
            var frozen = bill["splitAttachment"] as? [String: Any]
            let hadAttachment = frozen?["present"] as? Bool ?? (attachment != nil)
            if hadAttachment {
                guard let attachment else { throw ShortcutBillingError(message: "请继续连接原图到拆分保存动作，不能改变待重试请求的附件") }
                let keepOriginal = frozen?["keepOriginal"] as? Bool ?? UserDefaults.standard.bool(forKey: "flutter.attachmentKeepOriginal")
                let prepared = try ConfirmedBilling.attachmentPayload(attachment, keepOriginal: keepOriginal)
                guard let encoded = prepared["dataBase64"] as? String, let bytes = Data(base64Encoded: encoded),
                      let ext = prepared["extension"] as? String else { throw ShortcutBillingError(message: "附件准备失败，未提交") }
                let digest = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
                if let frozen {
                    guard frozen["sha256"] as? String == digest, frozen["extension"] as? String == ext else {
                        throw ShortcutBillingError(message: "附件与待重试原图不一致，请恢复原图，不能更改当前请求")
                    }
                } else { frozen = ["present": true, "keepOriginal": keepOriginal, "extension": ext, "sha256": digest] }
                payload["attachment"] = prepared
            } else {
                guard attachment == nil else { throw ShortcutBillingError(message: "当前待重试请求原本没有附件，不能中途增加") }
                frozen = ["present": false]
            }
            // Retain only attachment identity/settings in state, never base64
            // image bytes: large originals must not overflow the state budget.
            var retryBill = bill
            retryBill["splitAttachment"] = frozen
            retryRaw = try ConfirmedBilling.encode(retryBill)
            payload.removeValue(forKey: "splitAttachment")
            attemptedPayload = true
            // Query also checks canonical digest, including an explicitly chosen
            // attachment. Never accept a different payload with the same UUID.
            let found = try await call(["operation": "query_split", "submission": payload])
            if found["status"] as? String == "committed" { return try applied(found, bill: bill, context: ctx) }
            guard found["status"] as? String == "not_found" else { throw ShortcutBillingError(message: "当前笔查询结果无效") }
            UserDefaults.standard.set(bill["requestId"] as? String, forKey: "confirmedBillingLastRequestId")
            let receipt = try await call(["operation": "commit", "submission": payload])
            return try applied(receipt, bill: bill, context: ctx)
        } catch is CancellationError { throw CancellationError() }
        catch {
            // A commit may have completed before its reply was lost. Reconcile
            // the SAME payload, do not consume money on an error alone.
            if attemptedPayload, let receipt = try? await call(["operation": "query_split", "submission": payload]),
               receipt["status"] as? String == "committed",
               let next = try? applied(receipt, bill: bill, context: ctx) { return next }
            return try envelope("split-retry", context: ctx, submission: retryRaw,
                message: summary(ctx) + "\n当前笔保存未完成或结果未知，余额尚未推进。请求 ID：" + (bill["requestId"] as? String ?? "") +
                "\n请用同一步骤重试；若已在本机保存会复用回执，不另记一笔。" + error.localizedDescription)
        }
    }
}

@available(iOS 16.0, *)
struct SaveProgressiveSplitIntent: AppIntent {
    static var isDiscoverable = true
    static var title: LocalizedStringResource = "保存拆分当前笔（逐笔入账）"
    static var description: LocalizedStringResource = "仅当前笔已确认时真实入账；成功才更新余额。重试沿用同请求，失败返回待重试步骤，已保存的笔不会因结束而撤销。"
    static var openAppWhenRun = false
    @Parameter(title: "当前确认步骤") var step: SingleBillingStep
    @Parameter(title: "附带图片（可选）", inputConnectionBehavior: .never) var attachment: IntentFile?
    static var parameterSummary: some ParameterSummary { Summary("保存拆分当前笔 \(\.$step)") { \.$attachment } }
    @MainActor func perform() async throws -> some IntentResult & ReturnsValue<SingleBillingStep> {
        .result(value: try await ProgressiveSplitFlow.save(step, attachment: attachment))
    }
}

#endif
