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
  private static let maxThemePackageBytes = 48 * 1024 * 1024

  private var deepLinkChannelInstance: FlutterMethodChannel?
  private var pendingDeepLink: Any?
  private var themeImportGeneration: Int = 0
  private let themeImportQueue = DispatchQueue(label: "online.sylulive.theme.import", qos: .userInitiated)

  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    if let url = launchOptions?[.url] as? URL {
      handleIncomingURL(url)
    }
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  override func application(
    _ app: UIApplication,
    open url: URL,
    options: [UIApplication.OpenURLOptionsKey: Any] = [:]
  ) -> Bool {
    handleIncomingURL(url)
    return true
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
    let messenger = engineBridge.applicationRegistrar.messenger()
    registerWidgetChannel(messenger)
    registerDeepLinkChannel(messenger)
    registerPushChannel(messenger)
    dispatchPendingDeepLink()
  }

  func handleIncomingURL(_ url: URL) {
    if url.isFileURL && url.pathExtension.lowercased() == "sltheme" {
      enqueueIncomingThemeFile(url)
      return
    }
    receiveDeepLink(url.absoluteString)
  }

  func receiveDeepLink(_ rawValue: String) {
    pendingDeepLink = rawValue
    dispatchPendingDeepLink()
  }

  private func enqueueIncomingThemeFile(_ url: URL) {
    themeImportGeneration += 1
    let generation = themeImportGeneration
    let eventId = "theme-\(UUID().uuidString)"
    themeImportQueue.async { [weak self] in
      guard let self else { return }
      let accessed = url.startAccessingSecurityScopedResource()
      defer {
        if accessed {
          url.stopAccessingSecurityScopedResource()
        }
      }
      let fm = FileManager.default
      let incomingDir = fm.temporaryDirectory.appendingPathComponent("incoming-theme", isDirectory: true)
      try? fm.createDirectory(at: incomingDir, withIntermediateDirectories: true)
      if let items = try? fm.contentsOfDirectory(at: incomingDir, includingPropertiesForKeys: nil) {
        for item in items {
          try? fm.removeItem(at: item)
        }
      }
      let dest = incomingDir.appendingPathComponent("\(eventId).sltheme")
      do {
        guard let input = InputStream(url: url) else {
          self.deliverIncomingThemeResult(generation: generation, eventId: eventId, path: nil, error: "permission_denied")
          return
        }
        guard let output = OutputStream(url: dest, append: false) else {
          self.deliverIncomingThemeResult(generation: generation, eventId: eventId, path: nil, error: "read_failed")
          return
        }
        input.open()
        output.open()
        defer {
          input.close()
          output.close()
        }
        var total = 0
        var buffer = [UInt8](repeating: 0, count: 16 * 1024)
        while input.hasBytesAvailable {
          let read = input.read(&buffer, maxLength: buffer.count)
          if read < 0 {
            try? fm.removeItem(at: dest)
            self.deliverIncomingThemeResult(generation: generation, eventId: eventId, path: nil, error: "read_failed")
            return
          }
          if read == 0 { break }
          total += read
          if total > Self.maxThemePackageBytes {
            try? fm.removeItem(at: dest)
            self.deliverIncomingThemeResult(generation: generation, eventId: eventId, path: nil, error: "theme_too_large")
            return
          }
          let written = buffer.withUnsafeBufferPointer { ptr -> Int in
            guard let base = ptr.baseAddress else { return -1 }
            return output.write(base, maxLength: read)
          }
          if written < 0 {
            try? fm.removeItem(at: dest)
            self.deliverIncomingThemeResult(generation: generation, eventId: eventId, path: nil, error: "read_failed")
            return
          }
        }
        self.deliverIncomingThemeResult(generation: generation, eventId: eventId, path: dest.path, error: nil)
      }
    }
  }

  private func deliverIncomingThemeResult(generation: Int, eventId: String, path: String?, error: String?) {
    DispatchQueue.main.async { [weak self] in
      guard let self else { return }
      if self.themeImportGeneration != generation {
        if let path {
          try? FileManager.default.removeItem(atPath: path)
        }
        return
      }
      var payload: [String: Any] = [
        "type": "theme_file",
        "id": eventId,
      ]
      if let path { payload["path"] = path }
      if let error { payload["error"] = error }
      self.pendingDeepLink = payload
      self.dispatchPendingDeepLink()
    }
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
        if acknowledged == nil {
          self.pendingDeepLink = nil
        } else if let str = self.pendingDeepLink as? String, str == acknowledged {
          self.pendingDeepLink = nil
        } else if let map = self.pendingDeepLink as? [String: Any], (map["id"] as? String) == acknowledged {
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
