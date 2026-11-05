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
            intent: AutoBillingAppIntent(),
            phrases: [
                "在\(.applicationName)中截图记账",
                "用\(.applicationName)记账",
                "打开\(.applicationName)自动记账"
            ]
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
private enum ConfirmedBilling {
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
        let object = try decode(await AppIntentsBridge.request(payload))
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
        if ocr {
            let text: String = try await Task.detached {
                let request = VNRecognizeTextRequest()
                request.recognitionLevel = .accurate
                request.usesLanguageCorrection = true
                request.recognitionLanguages = ["zh-Hans", "en-US"]
                try VNImageRequestHandler(data: data).perform([request])
                return (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: "\n")
            }.value
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
        return try await call(input)
    }
    static func commit(_ submission: [String: Any]) async throws -> String {
        guard submission["confirmed"] as? Bool == true,
              let id = submission["requestId"] as? String else { throw ShortcutBillingError(message: "请先完成草稿确认") }
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
    static func summary(_ entry: [String: Any], categories: [[String: Any]], tags: [[String: Any]], digits: Int = 2) -> String {
        let tagNames = (entry["tagIds"] as? [Int] ?? []).map { label($0, tags) }.joined(separator: "、")
        return "金额：" + money(entry["amountMinor"] as? Int ?? 0, digits: digits) + "\n分类：" + label(entry["categoryId"] as? Int, categories) +
            "\n备注：" + (entry["note"] as? String ?? "") + "\n标签：" + (tagNames.isEmpty ? "无" : tagNames) +
            "\n预算：" + (entry["excludeFromBudget"] as? Bool == true ? "不计入" : "计入")
    }
}

@available(iOS 16.0, *)
struct BillingOptionsIntent: AppIntent {
    static var title: LocalizedStringResource = "获取快捷记账选项"
    static var openAppWhenRun = false
    @Parameter(title: "账本 ID") var ledgerId: Int?
    @MainActor func perform() async throws -> some IntentResult & ReturnsValue<String> {
        var input: [String: Any] = ["operation": "options"]
        if let ledgerId { input["ledgerId"] = ledgerId }
        return .result(value: try ConfirmedBilling.encode(await ConfirmedBilling.call(input)))
    }
}

@available(iOS 16.0, *)
struct ImageBillingDraftIntent: AppIntent {
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
    static var title: LocalizedStringResource = "文字生成记账草稿"
    static var description: LocalizedStringResource = "仅识别，不入账。只发送文字给 App 配置的文字服务，不发送原图。"
    static var openAppWhenRun = false
    @Parameter(title: "OCR 文字") var text: String
    @Parameter(title: "默认配置 JSON") var configuration: String?
    @MainActor func perform() async throws -> some IntentResult & ReturnsValue<String> {
        var input = try configuration.map(ConfirmedBilling.decode) ?? [:]
        input["operation"] = "recognize"; input["mode"] = "text"; input["text"] = text
        return .result(value: try ConfirmedBilling.encode(await ConfirmedBilling.call(input)))
    }
}

@available(iOS 16.0, *)
struct CommitConfirmedBillingIntent: AppIntent {
    static var title: LocalizedStringResource = "提交已确认支出"
    static var openAppWhenRun = false
    @Parameter(title: "已确认账单 JSON") var submission: String
    @MainActor func perform() async throws -> some IntentResult & ReturnsValue<String> {
        return .result(value: try await ConfirmedBilling.commit(ConfirmedBilling.decode(submission)))
    }
}

@available(iOS 16.0, *)
struct QueryConfirmedBillingIntent: AppIntent {
    static var title: LocalizedStringResource = "查询快捷记账结果"
    static var openAppWhenRun = false
    @Parameter(title: "请求 ID（留空查最近一次）") var requestId: String?
    @MainActor func perform() async throws -> some IntentResult & ReturnsValue<String> {
        let id = requestId ?? UserDefaults.standard.string(forKey: "confirmedBillingLastRequestId")
        let input: [String: Any] = id.map { ["operation": "query", "requestId": $0] } ?? ["operation": "recent"]
        return .result(value: try ConfirmedBilling.encode(await ConfirmedBilling.call(input)))
    }
}

@available(iOS 16.0, *)
struct EditBillingDraftIntent: AppIntent {
    static var title: LocalizedStringResource = "确认编辑支出草稿"
    static var description: LocalizedStringResource = "系统菜单编辑、逐笔拆分并最终确认。此动作本身不入账。"
    static var openAppWhenRun = false
    @Parameter(title: "草稿 JSON") var draft: String
    @Parameter(title: "菜单选择") var choice: String?
    @Parameter(title: "输入内容") var textValue: String?

    @MainActor private func choose(_ values: [String], _ prompt: String) async throws -> String {
        try await $choice.requestDisambiguation(among: values, dialog: IntentDialog(stringLiteral: prompt))
    }
    @MainActor private func input(_ prompt: String) async throws -> String {
        try await $textValue.requestValue(IntentDialog(stringLiteral: prompt))
    }
    @MainActor private func pick(_ values: [[String: Any]], _ prompt: String) async throws -> Int {
        guard !values.isEmpty else { throw ShortcutBillingError(message: "没有可选项，请先在 App 配置") }
        let labels = values.enumerated().map { String($0.offset + 1) + ". " + ($0.element["name"] as? String ?? "") }
        let selected = try await choose(labels, prompt)
        guard let index = labels.firstIndex(of: selected), let id = values[index]["id"] as? Int else { throw ShortcutBillingError(message: "选项已失效") }
        return id
    }
    @MainActor private func edit(_ initial: [String: Any], categories: [[String: Any]], tags: [[String: Any]], digits: Int) async throws -> [String: Any] {
        var entry = initial
        while true {
            let selected = try await choose(["完成此笔", "金额", "分类", "备注", "标签", "预算标记", "取消本次字段修改"], ConfirmedBilling.summary(entry, categories: categories, tags: tags, digits: digits))
            switch selected {
            case "完成此笔":
                guard (entry["amountMinor"] as? Int ?? 0) > 0, categories.contains(where: { $0["id"] as? Int == entry["categoryId"] as? Int }) else { continue }
                return entry
            case "金额":
                let value = try await input("当前 " + ConfirmedBilling.money(entry["amountMinor"] as? Int ?? 0, digits: digits) + "；输入新金额")
                if let amount = try? ConfirmedBilling.minor(value, digits: digits) { entry["amountMinor"] = amount }
            case "分类": entry["categoryId"] = try await pick(categories, "选择支出分类")
            case "备注":
                let old = entry["note"] as? String ?? ""
                let action = try await choose(["编辑", "追加", "清空重填", "保存空备注", "取消修改"], "原备注：" + old)
                if action == "保存空备注" { entry["note"] = "" }
                else if action != "取消修改" {
                    if let value = try? await input((action == "追加" ? "追加内容；原备注：" : "输入最终备注；原备注：") + old) {
                        entry["note"] = action == "追加" ? old + value : value
                    }
                }
            case "标签":
                var selectedTags = entry["tagIds"] as? [Int] ?? []
                while true {
                    let labels = tags.map { (selectedTags.contains($0["id"] as? Int ?? -1) ? "✓ " : "○ ") + ($0["name"] as? String ?? "") + " [" + String($0["id"] as? Int ?? -1) + "]" }
                    let value = try await choose(["完成标签选择", "清空所有标签"] + labels, "可反复点选多个标签")
                    if value == "完成标签选择" { break }
                    if value == "清空所有标签" { selectedTags = []; continue }
                    if let index = labels.firstIndex(of: value), let id = tags[index]["id"] as? Int {
                        if selectedTags.contains(id) { selectedTags.removeAll { $0 == id } } else { selectedTags.append(id) }
                    }
                }
                entry["tagIds"] = selectedTags.sorted()
            case "预算标记": entry["excludeFromBudget"] = try await choose(["计入预算", "不计入预算"], "仅影响预算，仍正常计支出") == "不计入预算"
            default: return initial
            }
        }
    }

    @MainActor func perform() async throws -> some IntentResult & ReturnsValue<String> {
        .result(value: try await runEditor())
    }

    @MainActor func runEditor() async throws -> String {
        let source = try ConfirmedBilling.decode(draft)
        guard source["status"] as? String == "draft", let ledgerId = source["ledgerId"] as? Int else { throw ShortcutBillingError(message: "请先生成草稿") }
        // Fresh references after recognition; no bridge call stays open while editing.
        let options = try await ConfirmedBilling.call(["operation": "options", "ledgerId": ledgerId])
        let digits = options["minorDigits"] as? Int ?? 2
        let currency = options["currency"] as? String ?? "CNY"
        let categories = options["categories"] as? [[String: Any]] ?? []
        let accounts = options["accounts"] as? [[String: Any]] ?? []
        let tags = options["tags"] as? [[String: Any]] ?? []
        let defaults = options["defaults"] as? [String: Any] ?? [:]
        let candidates = source["candidates"] as? [[String: Any]] ?? []
        var candidate: [String: Any]
        if candidates.count > 1 {
            let labels = candidates.enumerated().map { String($0.offset + 1) + ". " + ConfirmedBilling.money($0.element["amountMinor"] as? Int ?? 0, digits: digits) + " " + ($0.element["merchant"] as? String ?? "") }
            let selected = try await choose(labels + ["人工填写", "取消"], "识别到多个候选，请只选择本次付款")
            if selected == "取消" { throw ShortcutBillingError(message: "已取消，未入账") }
            candidate = labels.firstIndex(of: selected).map { candidates[$0] } ?? [:]
        } else { candidate = candidates.first ?? [:] }
        if candidate["blocked"] as? Bool == true {
            let action = try await choose(["核对后人工填写支出", "取消"], "识别到非支出或币种冲突，不可直接提交")
            if action == "取消" { throw ShortcutBillingError(message: "已取消，未入账") }
            candidate = [:]
        }
        if let warnings = candidate["warnings"] as? [String], !warnings.isEmpty {
            if try await choose(["继续核对", "取消"], warnings.joined(separator: "\n")) == "取消" { throw ShortcutBillingError(message: "已取消，未入账") }
        }
        var total = candidate["amountMinor"] as? Int ?? 0
        while total <= 0 { total = (try? ConfirmedBilling.minor(await input("输入本次付款金额（" + currency + "）"), digits: digits)) ?? 0 }
        var accountId = candidate["accountId"] as? Int ?? defaults["accountId"] as? Int
        if !accounts.contains(where: { $0["id"] as? Int == accountId }) { accountId = try await pick(accounts, "选择付款账户") }
        var time = candidate["occurredAt"] as? String ?? ISO8601DateFormatter().string(from: Date())
        var entries: [[String: Any]] = [["amountMinor": total, "note": candidate["note"] as? String ?? "",
            "tagIds": candidate["tagIds"] as? [Int] ?? defaults["tagIds"] as? [Int] ?? [],
            "excludeFromBudget": candidate["excludeFromBudget"] as? Bool ?? defaults["excludeFromBudget"] as? Bool ?? false]]
        if let categoryId = candidate["categoryId"] as? Int { entries[0]["categoryId"] = categoryId }
        var didSplit = false
        while true {
            let used = entries.reduce(0) { $0 + ($1["amountMinor"] as? Int ?? 0) }
            let detail = entries.enumerated().map { "第 " + String($0.offset + 1) + " 笔\n" + ConfirmedBilling.summary($0.element, categories: categories, tags: tags, digits: digits) }.joined(separator: "\n")
            let excess = used > total ? "（超额 " + ConfirmedBilling.money(used - total, digits: digits) + "，请修改）" : ""
            let summary = "付款 " + ConfirmedBilling.money(total, digits: digits) + " " + currency + " · 账户 " + ConfirmedBilling.label(accountId, accounts) + "\n时间：" + time + "\n剩余：" + ConfirmedBilling.money(max(0, total - used), digits: digits) + excess + "\n" + detail
            let action = try await choose(["确认提交", "编辑明细", "拆分或新增明细", "删除明细", "修改原付款金额", "付款账户", "日期时间", "取消整次记账"], summary)
            switch action {
            case "取消整次记账": throw ShortcutBillingError(message: "已取消，未入账")
            case "付款账户": accountId = try await pick(accounts, "选择付款账户")
            case "日期时间":
                let value = try await input("当前 " + time + "；输入完整日期时间，如 2026-11-05T18:30:00+08:00")
                if ISO8601DateFormatter().date(from: value) != nil { time = value }
            case "修改原付款金额":
                if let amount = try? ConfirmedBilling.minor(await input("输入原付款总额"), digits: digits) { total = amount; if !didSplit && entries.count == 1 { entries[0]["amountMinor"] = amount } }
            case "拆分或新增明细":
                if !didSplit {
                    if try await choose(["开始拆分", "返回"], "原整笔草稿将替换为逐笔明细，暂不入账") == "返回" { continue }
                    entries = []; didSplit = true
                }
                guard entries.count < 100 else { continue }
                let remaining = total - entries.reduce(0) { $0 + ($1["amountMinor"] as? Int ?? 0) }
                guard remaining > 0 else { continue }
                var entry: [String: Any] = ["amountMinor": remaining, "note": candidate["note"] as? String ?? "", "tagIds": candidate["tagIds"] as? [Int] ?? defaults["tagIds"] as? [Int] ?? [], "excludeFromBudget": candidate["excludeFromBudget"] as? Bool ?? defaults["excludeFromBudget"] as? Bool ?? false]
                entry = try await edit(entry, categories: categories, tags: tags, digits: digits)
                if (entry["amountMinor"] as? Int ?? 0) <= remaining && entry["categoryId"] is Int { entries.append(entry) }
            case "编辑明细", "删除明细":
                guard !entries.isEmpty else { continue }
                let labels = entries.enumerated().map { "第 " + String($0.offset + 1) + " 笔 " + ConfirmedBilling.money($0.element["amountMinor"] as? Int ?? 0, digits: digits) }
                let selected = try await choose(labels + ["返回"], "选择明细")
                guard let index = labels.firstIndex(of: selected) else { continue }
                if action == "删除明细" { entries.remove(at: index); didSplit = true }
                else { entries[index] = try await edit(entries[index], categories: categories, tags: tags, digits: digits) }
            case "确认提交":
                guard !entries.isEmpty, used == total, entries.allSatisfy({ entry in
                    (entry["amountMinor"] as? Int ?? 0) > 0 && categories.contains { $0["id"] as? Int == entry["categoryId"] as? Int }
                }) else { _ = try await choose(["返回修改"], "金额尚未分配完、超额或分类未选择，不能提交"); continue }
                let submission: [String: Any] = ["schemaVersion": 1, "confirmed": true, "requestId": source["requestId"] as? String ?? UUID().uuidString,
                    "ledgerId": ledgerId, "accountId": accountId!, "type": "expense", "occurredAt": time,
                    "originalAmountMinor": total, "entries": entries]
                return try ConfirmedBilling.encode(submission)
            default: break
            }
        }
    }
}

@available(iOS 16.0, *)
struct RecognizeConfirmBillingIntent: AppIntent {
    static var title: LocalizedStringResource = "识别并确认记账"
    static var description: LocalizedStringResource = "图片或本地 OCR 识别，系统菜单编辑和拆分，最终一次确认直接入账。"
    static var openAppWhenRun = false
    @Parameter(title: "图片") var image: IntentFile
    @Parameter(title: "使用本地 OCR 后文字 AI（留空跟随 App）") var useOCR: Bool?
    @Parameter(title: "默认配置 JSON") var configuration: String?
    @Parameter(title: "菜单") var choice: String?
    @MainActor func perform() async throws -> some IntentResult & ReturnsValue<String> & ProvidesDialog {
        let config = try configuration.map(ConfirmedBilling.decode) ?? [:]
        let options = try await ConfirmedBilling.call(config.merging(["operation": "options"]) { _, new in new })
        let defaults = options["defaults"] as? [String: Any] ?? [:]
        let ocr = useOCR ?? ((config["mode"] as? String ?? defaults["mode"] as? String ?? "image") == "text")
        // Consent before sending bill data. No automatic image fallback.
        let privacy = ocr ? "在本机取字，仅将文字发送给 App 配置的文字 AI 服务。" : "图片将发送给 App 配置的视觉 AI 服务。"
        if try await $choice.requestDisambiguation(among: ["继续识别", "取消"], dialog: IntentDialog(stringLiteral: privacy)) == "取消" { throw ShortcutBillingError(message: "已取消，未入账") }
        var draft: [String: Any]
        do { draft = try await ConfirmedBilling.recognizeImage(image, ocr: ocr, configuration: configuration) }
        catch {
            if try await $choice.requestDisambiguation(among: ["人工填写", "取消"], dialog: "识别未完成，未入账。可人工填写；不会自动上传原图。") == "取消" { throw error }
            let defaults = try configuration.map(ConfirmedBilling.decode) ?? [:]
            let options = try await ConfirmedBilling.call(defaults.merging(["operation": "options"]) { _, new in new })
            draft = ["status": "draft", "requestId": UUID().uuidString, "ledgerId": options["ledgerId"]!, "candidates": []]
        }
        var editor = EditBillingDraftIntent()
        editor.draft = try ConfirmedBilling.encode(draft)
        let edited = try await editor.runEditor()
        let result = try await ConfirmedBilling.commit(ConfirmedBilling.decode(edited))
        let object = try ConfirmedBilling.decode(result)
        let message = "已入账 " + String(object["count"] as? Int ?? 0) + " 条，合计 " + ConfirmedBilling.money(object["totalAmountMinor"] as? Int ?? 0, digits: object["minorDigits"] as? Int ?? 2) + " " + (object["currency"] as? String ?? "CNY") + "。云端尚未确认，请查看 App 同步状态，无需重记。"
        return .result(value: result, dialog: IntentDialog(stringLiteral: message))
    }
}
#endif
