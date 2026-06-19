import Flutter
import UIKit
import UserNotifications

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  private var pushChannel: FlutterMethodChannel?
  /// A room id captured from a notification tap that cold-launched the app,
  /// held until Dart asks for it once the inbox is ready.
  private var pendingLaunchRoomId: String?

  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    UNUserNotificationCenter.current().delegate = self
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
    let messenger = engineBridge.applicationRegistrar.messenger()
    let channel = FlutterMethodChannel(name: "little_love/push", binaryMessenger: messenger)
    channel.setMethodCallHandler { [weak self] call, result in
      guard let self = self else { return }
      switch call.method {
      case "requestPermission":
        self.requestPermission(result)
      case "takePendingLaunchRoom":
        let room = self.pendingLaunchRoomId
        self.pendingLaunchRoomId = nil
        result(room)
      case "setPalette":
        if let key = call.arguments as? String {
          UserDefaults(suiteName: "group.dev.littlelove.littlelove")?
            .set(key, forKey: "selected_palette")
        }
        result(nil)
      case "setBadge":
        if let n = call.arguments as? Int {
          let center = UNUserNotificationCenter.current()
          // applicationIconBadgeNumber is deprecated since iOS 17 and unreliable
          // on iOS 18+; setBadgeCount is the supported path (iOS 16+).
          if #available(iOS 16.0, *) {
            center.setBadgeCount(n)
          } else {
            UIApplication.shared.applicationIconBadgeNumber = n
          }
          // setBadgeCount(0) drops the icon badge but leaves delivered banners in
          // Notification Center, and those re-assert a badge on the next glance.
          // When clearing, sweep them too so "I've read everything" really sticks.
          if n == 0 {
            center.removeAllDeliveredNotifications()
          }
        }
        result(nil)
      default:
        result(FlutterMethodNotImplemented)
      }
    }
    self.pushChannel = channel
  }

  private func requestPermission(_ result: @escaping FlutterResult) {
    UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) {
      granted, _ in
      if granted {
        DispatchQueue.main.async { UIApplication.shared.registerForRemoteNotifications() }
      }
      result(granted)
    }
  }

  override func application(
    _ application: UIApplication,
    didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data
  ) {
    let hex = deviceToken.map { String(format: "%02x", $0) }.joined()
    pushChannel?.invokeMethod(
      "onToken",
      arguments: ["token": hex, "environment": Self.apnsEnvironment()])
  }

  /// The APNs environment this build's token belongs to, read from the embedded
  /// provisioning profile's `aps-environment` entitlement — NOT the Debug/Release
  /// build config (a Release build signed with a development profile still mints
  /// sandbox tokens). `development` → sandbox, `production` → production. An App
  /// Store build has no embedded profile, so we default to production.
  private static func apnsEnvironment() -> String {
    guard
      let url = Bundle.main.url(forResource: "embedded", withExtension: "mobileprovision"),
      let data = try? Data(contentsOf: url),
      // .isoLatin1 maps every byte 0–255 to a scalar (never nil); the profile is
      // a binary CMS blob, so .ascii/.utf8 would fail on the signature bytes and
      // drop us to the production fallback — registering sandbox tokens as prod.
      let raw = String(data: data, encoding: .isoLatin1),
      let start = raw.range(of: "<plist"),
      let end = raw.range(of: "</plist>")
    else { return "production" }
    let plist = String(raw[start.lowerBound..<end.upperBound])
    guard
      let plistData = plist.data(using: .utf8),
      let parsed = try? PropertyListSerialization.propertyList(from: plistData, options: [], format: nil),
      let dict = parsed as? [String: Any],
      let entitlements = dict["Entitlements"] as? [String: Any],
      let aps = entitlements["aps-environment"] as? String
    else { return "production" }
    return aps == "development" ? "sandbox" : "production"
  }

  override func application(
    _ application: UIApplication,
    didFailToRegisterForRemoteNotificationsWithError error: Error
  ) {
    NSLog("little_love: remote notification registration failed: \(error)")
  }

  // Foreground: suppress the banner — the in-app UI already shows the message.
  override func userNotificationCenter(
    _ center: UNUserNotificationCenter,
    willPresent notification: UNNotification,
    withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
  ) {
    completionHandler([])
  }

  // Tap: deep-link to the room. Buffer it if Dart isn't ready (cold launch).
  override func userNotificationCenter(
    _ center: UNUserNotificationCenter,
    didReceive response: UNNotificationResponse,
    withCompletionHandler completionHandler: @escaping () -> Void
  ) {
    if let roomId = response.notification.request.content.userInfo["room_id"] as? String {
      pendingLaunchRoomId = roomId
      pushChannel?.invokeMethod("onTap", arguments: roomId)
    }
    completionHandler()
  }
}
