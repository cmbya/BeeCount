import Flutter
import UIKit
import UserNotifications
import WidgetKit

@main
@objc class AppDelegate: FlutterAppDelegate {
  private var dailySpendingChannel: FlutterMethodChannel?
  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    GeneratedPluginRegistrant.register(with: self)

    // 注册AppIntents桥接插件
    if #available(iOS 13.0, *) {
      let controller = window?.rootViewController as! FlutterViewController
      let registrar = self.registrar(forPlugin: "AppIntentsBridge")
      if let registrar = registrar {
        AppIntentsBridge.register(with: registrar)
      }
    }

    // 设置通知中心代理
    if #available(iOS 10.0, *) {
      UNUserNotificationCenter.current().delegate = self
    }

    // 设置日志插件
    let controller = window?.rootViewController as! FlutterViewController
    let loggerChannel = FlutterMethodChannel(
      name: "com.beecount.logger",
      binaryMessenger: controller.binaryMessenger
    )
    LoggerPlugin.setup(channel: loggerChannel)
    setupDailySpendingWidget(messenger: controller.binaryMessenger)

    // 监听 iCloud 日志（从插件模块发送）
    NotificationCenter.default.addObserver(
      forName: NSNotification.Name("ICloudLog"),
      object: nil,
      queue: .main
    ) { notification in
      if let message = notification.userInfo?["message"] as? String {
        LoggerPlugin.info(tag: "iCloud", message: message)
      }
    }

    // 测试日志
    LoggerPlugin.info(tag: "AppDelegate", message: "日志系统已初始化")

    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  override func applicationDidBecomeActive(_ application: UIApplication) {
    super.applicationDidBecomeActive(application)
    clearNotificationBadge()
  }

  private func clearNotificationBadge() {
    if #available(iOS 16.0, *) {
      UNUserNotificationCenter.current().setBadgeCount(0) { error in
        if let error = error {
          LoggerPlugin.info(tag: "AppDelegate", message: "清除通知角标失败: \(error.localizedDescription)")
        }
      }
    } else {
      UIApplication.shared.applicationIconBadgeNumber = 0
    }
  }

  // 前台显示通知
  @available(iOS 10.0, *)
  override func userNotificationCenter(
    _ center: UNUserNotificationCenter,
    willPresent notification: UNNotification,
    withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
  ) {
    // 前台保留横幅和声音，避免正在使用 App 时重新留下未读角标。
    if #available(iOS 14.0, *) {
      completionHandler([.banner, .sound])
    } else {
      completionHandler([.alert, .sound])
    }
  }

  // 处理通知点击
  @available(iOS 10.0, *)
  override func userNotificationCenter(
    _ center: UNUserNotificationCenter,
    didReceive response: UNNotificationResponse,
    withCompletionHandler completionHandler: @escaping () -> Void
  ) {
    clearNotificationBadge()
    completionHandler()
  }

  private func setupDailySpendingWidget(messenger: FlutterBinaryMessenger) {
    let channel = FlutterMethodChannel(name: "com.beecount.daily_spending_widget", binaryMessenger: messenger)
    dailySpendingChannel = channel
    channel.setMethodCallHandler { call, result in
      do {
        switch call.method {
        case "diagnostics":
          result(DailySpendingSharedStore.diagnostics())
        case "chooseGroup":
          guard let args = call.arguments as? [String: Any], let group = args["group"] as? String else {
            result(FlutterError(code: "invalidArgument", message: "请选择有效共享组", details: nil)); return
          }
          try DailySpendingSharedStore.choose(group)
          result(nil)
        case "publish":
          guard let args = call.arguments as? [String: Any], let raw = args["payload"] as? String,
                raw.utf8.count < 65536 else {
            result(FlutterError(code: "invalidArgument", message: "组件快照无效", details: nil)); return
          }
          let group = try DailySpendingSharedStore.write(raw)
          WidgetCenter.shared.reloadTimelines(ofKind: DailySpendingSharedStore.kind)
          result(["verified": true, "group": group])
        default:
          result(FlutterMethodNotImplemented)
        }
      } catch let error as DailySpendingStorageError {
        result(FlutterError(code: error.rawValue, message: error.message, details: nil))
      } catch {
        result(FlutterError(code: "storageFailed", message: "共享数据操作失败，未改动账本", details: nil))
      }
    }
  }

}
