import Flutter
import Foundation
import UIKit
import UserNotifications
import WidgetKit

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  private static let appGroup = "group.com.sylu.sylulive"
  private static let widgetChannel = "shenliyuan/widget"
  private static let deepLinkChannel = "shenliyuan/deeplink"
  private static let pushChannel = "shenliyuan/private_message_notifications"

  private var deepLinkChannelInstance: FlutterMethodChannel?
  private var pendingDeepLink: String?

  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    if let url = launchOptions?[.url] as? URL {
      pendingDeepLink = url.absoluteString
    }
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
    let messenger = engineBridge.applicationRegistrar.messenger()
    registerWidgetChannel(messenger)
    registerDeepLinkChannel(messenger)
    registerPushChannel(messenger)
    dispatchPendingDeepLink()
  }

  func receiveDeepLink(_ rawValue: String) {
    pendingDeepLink = rawValue
    dispatchPendingDeepLink()
  }

  private func registerWidgetChannel(_ messenger: FlutterBinaryMessenger) {
    FlutterMethodChannel(name: Self.widgetChannel, binaryMessenger: messenger)
      .setMethodCallHandler { [weak self] call, result in
        guard let self else {
          result(FlutterError(code: "APP_DELEGATE_GONE", message: nil, details: nil))
          return
        }
        guard call.method == "updateWidget" else {
          result(FlutterMethodNotImplemented)
          return
        }

        if let arguments = call.arguments as? [String: Any] {
          let defaults = UserDefaults(suiteName: Self.appGroup)
          if let course = arguments["course_data"] as? String {
            defaults?.set(course, forKey: "widget_course_data")
          }
          if let exam = arguments["exam_data"] as? String {
            defaults?.set(exam, forKey: "widget_exam_data")
          }
          defaults?.set(Date().timeIntervalSince1970, forKey: "widget_updated_at")
          defaults?.synchronize()
        }
        if #available(iOS 14.0, *) {
          WidgetCenter.shared.reloadTimelines(ofKind: "CourseScheduleWidget")
          WidgetCenter.shared.reloadTimelines(ofKind: "ExamScheduleWidget")
        }
        result(nil)
      }
  }

  private func registerDeepLinkChannel(_ messenger: FlutterBinaryMessenger) {
    deepLinkChannelInstance = FlutterMethodChannel(
      name: Self.deepLinkChannel,
      binaryMessenger: messenger
    )
    deepLinkChannelInstance?.setMethodCallHandler { [weak self] call, result in
      guard let self else {
        result(FlutterError(code: "APP_DELEGATE_GONE", message: nil, details: nil))
        return
      }
      switch call.method {
      case "getPendingDeepLink":
        result(self.pendingDeepLink)
      case "ackPendingDeepLink":
        let acknowledged = (call.arguments as? [String: Any])?["link"] as? String
        if acknowledged == nil || acknowledged == self.pendingDeepLink {
          self.pendingDeepLink = nil
        }
        result(nil)
      default:
        result(FlutterMethodNotImplemented)
      }
    }
  }

  private func registerPushChannel(_ messenger: FlutterBinaryMessenger) {
    FlutterMethodChannel(name: Self.pushChannel, binaryMessenger: messenger)
      .setMethodCallHandler { call, result in
        switch call.method {
        case "setPushOptIn", "syncAlias", "clearAlias":
          // JPush alias/开关由 Dart 端 JPushClient 执行；此通道保留给现有
          // Android-first 调用方，避免 iOS 因通道缺失阻断推送登记。
          result(true)
        case "openAppNotificationSettings", "openNotificationChannelSettings":
          guard let settingsURL = URL(string: UIApplication.openSettingsURLString) else {
            result(false)
            return
          }
          UIApplication.shared.open(settingsURL) { opened in result(opened) }
        case "getPushDiagnostics":
          UNUserNotificationCenter.current().getNotificationSettings { settings in
            let enabled = settings.authorizationStatus == .authorized ||
              settings.authorizationStatus == .provisional ||
              settings.authorizationStatus == .ephemeral
            result([
              "notificationsEnabled": enabled,
              "privateMessageChannelExists": true,
              "privateMessageChannelBlocked": false,
              "storedAliasState": "bound",
            ])
          }
        default:
          result(FlutterMethodNotImplemented)
        }
      }
  }

  private func dispatchPendingDeepLink() {
    guard let pendingDeepLink else { return }
    deepLinkChannelInstance?.invokeMethod("onDeepLink", arguments: pendingDeepLink)
  }
}
