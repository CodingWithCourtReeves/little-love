import AVFoundation
import AudioToolbox
import CallKit
import Flutter
import PushKit
import UIKit
import UserNotifications
import WebRTC
import flutter_callkit_incoming

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate, PKPushRegistryDelegate,
  CallkitIncomingAppDelegate
{
  private var pushChannel: FlutterMethodChannel?
  /// A room id captured from a notification tap that cold-launched the app,
  /// held until Dart asks for it once the inbox is ready.
  private var pendingLaunchRoomId: String?
  /// Whether the current call is a video call. Set by Dart before the call
  /// connects; read in `didActivateAudioSession` to default the route to the
  /// speaker (hands-free) the instant CallKit activates the session — doing it
  /// here is the only place that wins the race against CallKit, which resets the
  /// route to the earpiece when it activates. The user can still toggle after.
  private var videoCallActive = false
  /// Whether the user wants the loud speaker for the current video call (the
  /// hands-free default; flipped by the in-call audio toggle). Gates the reactive
  /// re-assertion in `applyVideoSpeakerRoute` so we never fight a deliberate
  /// switch to the earpiece.
  private var speakerPreferred = true
  /// Native → Dart channel for capture-privacy events (screenshot / screen
  /// recording) detected on THIS device during a video call.
  private var callPrivacyChannel: FlutterMethodChannel?
  /// Opaque cover laid over the window while a video call is backgrounding, so
  /// the live feed never lands in the app-switcher snapshot.
  private var privacyCover: UIView?
  /// PushKit registry for VoIP (call) wakes — distinct from the alert APNs
  /// registration above. Retained for the app's lifetime.
  private var voipRegistry: PKPushRegistry?
  /// In-room message chime channel + its preloaded system-sound ids (created
  /// lazily from the bundled WAVs on first play, then reused). Played via
  /// AudioServicesPlaySystemSound so they respect the hardware silent switch,
  /// mix with other audio, and never touch the call/voice AVAudioSession.
  private var messageSoundChannel: FlutterMethodChannel?
  private var sentSoundID: SystemSoundID = 0
  private var receivedSoundID: SystemSoundID = 0

  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    UNUserNotificationCenter.current().delegate = self
    // Register for VoIP pushes. The token arrives in `didUpdate` and is sent to
    // Dart (which registers it server-side as a `voip`-kind token).
    let registry = PKPushRegistry(queue: .main)
    registry.delegate = self
    registry.desiredPushTypes = [.voIP]
    self.voipRegistry = registry

    // Hand WebRTC's audio session to CallKit: WebRTC must NOT auto-activate the
    // session; CallKit owns activation so audio routes to the system-chosen
    // output (earpiece, speaker, AirPods, Bluetooth, CarPlay). We enable audio
    // only in the CallKit `didActivate` callback below.
    let rtcAudio = RTCAudioSession.sharedInstance()
    rtcAudio.useManualAudio = true
    rtcAudio.isAudioEnabled = false

    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  // MARK: - CallkitIncomingAppDelegate (audio session + action fulfilment)

  // The plugin already forwards accept/decline/end to Dart via its event stream
  // (our CallController handles the call logic there). When we conform to this
  // protocol the plugin stops auto-fulfilling the CXActions, so we just fulfil
  // them here to complete the CallKit transaction.
  func onAccept(_ call: Call, _ action: CXAnswerCallAction) { action.fulfill() }
  func onDecline(_ call: Call, _ action: CXEndCallAction) { action.fulfill() }
  func onEnd(_ call: Call, _ action: CXEndCallAction) { action.fulfill() }
  func onTimeOut(_ call: Call) {}

  func didActivateAudioSession(_ audioSession: AVAudioSession) {
    let rtc = RTCAudioSession.sharedInstance()
    rtc.audioSessionDidActivate(audioSession)
    rtc.isAudioEnabled = true
    // Video calls are hands-free. The global webRTC config (set in
    // configureAudioForVideo) brings the session up on the speaker, but re-assert
    // the videoChat mode + speaker override here too: WebRTC starts its audio
    // unit right after this and would otherwise settle on the earpiece.
    if videoCallActive {
      rtc.lockForConfiguration()
      do {
        try rtc.setCategory(
          .playAndRecord,
          mode: .videoChat,
          options: [.defaultToSpeaker, .allowBluetooth, .allowBluetoothA2DP])
        try rtc.overrideOutputAudioPort(.speaker)
      } catch {
        NSLog("little_love: speaker route failed: \(error)")
      }
      rtc.unlockForConfiguration()
    }
  }

  /// Re-assert the speaker for a video call. flutter_webrtc's audio unit settles
  /// into `voiceChat` mode a few seconds after the session activates, which silently
  /// drops the route back to the earpiece (flutter-webrtc issues #1098 / #1987 — the
  /// plugin overrides `RTCAudioSession` but its route-change observer watches a
  /// different session, so the override never sticks). We watch the route ourselves
  /// (`onAudioRouteChange`) and flip it back. Only the built-in earpiece is
  /// overridden — headphones, Bluetooth, CarPlay and an already-active speaker are
  /// left alone, and we stand down entirely once the user picks the earpiece.
  private func applyVideoSpeakerRoute() {
    guard videoCallActive, speakerPreferred else { return }
    let outputs = AVAudioSession.sharedInstance().currentRoute.outputs
    guard outputs.contains(where: { $0.portType == .builtInReceiver }) else { return }
    let rtc = RTCAudioSession.sharedInstance()
    rtc.lockForConfiguration()
    do { try rtc.overrideOutputAudioPort(.speaker) } catch {
      NSLog("little_love: re-assert speaker failed: \(error)")
    }
    rtc.unlockForConfiguration()
  }

  /// Configure WebRTC's shared audio config so a video call defaults to the
  /// speaker (videoChat mode + defaultToSpeaker); restore voiceChat (earpiece)
  /// when it ends. Set BEFORE the session activates so WebRTC comes up on the
  /// speaker rather than racing an after-the-fact override.
  private func configureAudioForVideo(_ speaker: Bool) {
    let cfg = RTCAudioSessionConfiguration.webRTC()
    cfg.category = AVAudioSession.Category.playAndRecord.rawValue
    cfg.mode =
      (speaker ? AVAudioSession.Mode.videoChat : AVAudioSession.Mode.voiceChat)
      .rawValue
    var options: AVAudioSession.CategoryOptions = [
      .allowBluetooth, .allowBluetoothA2DP,
    ]
    if speaker { options.insert(.defaultToSpeaker) }
    cfg.categoryOptions = options
    RTCAudioSessionConfiguration.setWebRTC(cfg)
  }

  func didDeactivateAudioSession(_ audioSession: AVAudioSession) {
    let rtc = RTCAudioSession.sharedInstance()
    rtc.audioSessionDidDeactivate(audioSession)
    rtc.isAudioEnabled = false
  }

  // MARK: - PushKit (VoIP)

  func pushRegistry(
    _ registry: PKPushRegistry, didUpdate credentials: PKPushCredentials, for type: PKPushType
  ) {
    guard type == .voIP else { return }
    let hex = credentials.token.map { String(format: "%02x", $0) }.joined()
    // Let the CallKit plugin know the token too (its own bookkeeping)...
    SwiftFlutterCallkitIncomingPlugin.sharedInstance?.setDevicePushTokenVoIP(hex)
    // ...and hand it to Dart for server registration, with the APNs environment
    // resolved the same way as the alert token (same provisioning profile).
    pushChannel?.invokeMethod(
      "onVoipToken",
      arguments: ["token": hex, "environment": Self.apnsEnvironment()])
  }

  func pushRegistry(
    _ registry: PKPushRegistry, didInvalidatePushTokenFor type: PKPushType
  ) {
    guard type == .voIP else { return }
    pushChannel?.invokeMethod("onVoipTokenInvalidated", arguments: nil)
  }

  /// A VoIP push arrived — wakes the app even from a cold start. iOS 13+ REQUIRES
  /// that every VoIP push report a CallKit incoming call and call `completion()`,
  /// or the app is killed and VoIP delivery is eventually disabled. So we ALWAYS
  /// show CallKit here (the plugin reports it to the system), then complete.
  func pushRegistry(
    _ registry: PKPushRegistry,
    didReceiveIncomingPushWith payload: PKPushPayload,
    for type: PKPushType,
    completion: @escaping () -> Void
  ) {
    guard type == .voIP else {
      completion()
      return
    }
    let dict = payload.dictionaryPayload
    let callId = (dict["call_id"] as? String) ?? UUID().uuidString
    let roomId = (dict["room_id"] as? String) ?? ""
    // Whether this is a video call — shapes the native CallKit screen (the green
    // video affordance) before any SDP is decrypted. Not secret; sent as plain
    // custom data on the VoIP push.
    let isVideo = (dict["video"] as? Bool) ?? false
    // Resolve the caller name LOCALLY (never from the push) to keep call
    // metadata off APNs — E2EE/privacy posture, same as our content-free message
    // pushes. A couple has exactly one partner, so the app stashes their name in
    // the shared App Group when known; we read it here on the wake.
    let caller =
      UserDefaults(suiteName: "group.dev.littlelove.littlelove")?
      .string(forKey: "partner_name") ?? "Partner"

    let info: [String: Any?] = [
      "id": callId,
      "nameCaller": caller,
      "handle": caller,
      "type": isVideo ? 1 : 0,  // 1 = video, 0 = audio
      "extra": ["room_id": roomId, "call_id": callId, "video": isVideo],
      "ios": ["handleType": "generic", "supportsVideo": isVideo],
    ]
    SwiftFlutterCallkitIncomingPlugin.sharedInstance?.showCallkitIncoming(
      flutter_callkit_incoming.Data(args: info), fromPushKit: true)
    // Give CallKit a beat to present before completing (per plugin guidance).
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { completion() }
  }

  // NOTE: universal links (`https://…/pair/<code>`) are NOT handled here. This
  // app uses the UIScene lifecycle, so iOS delivers them to `SceneDelegate`,
  // never to `application(_:continue:)`. See SceneDelegate.swift.

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
      case "apnsEnvironment":
        // The APNs environment (sandbox/production) for this build's tokens,
        // resolved from the embedded profile. Used to register the VoIP token,
        // which shares the alert token's environment.
        result(Self.apnsEnvironment())
      case "setPalette":
        if let key = call.arguments as? String {
          UserDefaults(suiteName: "group.dev.littlelove.littlelove")?
            .set(key, forKey: "selected_palette")
        }
        result(nil)
      case "setVideoCallActive":
        // Dart flags a video call so didActivateAudioSession can default to the
        // speaker. Cleared when the call ends. Also gates capture-privacy
        // observers to the duration of a video call.
        let active = (call.arguments as? Bool) ?? false
        self.videoCallActive = active
        // Each video call starts hands-free (speaker); the in-call toggle flips it.
        if active { self.speakerPreferred = true }
        // Bring WebRTC's audio config to speaker-default for video BEFORE the
        // session activates (avoids the earpiece race).
        self.configureAudioForVideo(active)
        if active {
          self.startCaptureObservers()
        } else {
          self.stopCaptureObservers()
        }
        result(nil)
      case "setSpeakerPreferred":
        // In-call audio toggle for video calls. We route this through native
        // (not flutter_webrtc's setSpeakerphoneOn, which doesn't stick — #1098)
        // so it cooperates with our reactive re-assertion.
        let on = (call.arguments as? Bool) ?? true
        self.speakerPreferred = on
        let rtc = RTCAudioSession.sharedInstance()
        rtc.lockForConfiguration()
        do { try rtc.overrideOutputAudioPort(on ? .speaker : .none) } catch {
          NSLog("little_love: toggle speaker(\(on)) failed: \(error)")
        }
        rtc.unlockForConfiguration()
        result(nil)
      case "setPartnerName":
        // Stash the partner's display name locally so a VoIP-wake CallKit screen
        // can name the caller without the push ever carrying it (E2EE/privacy).
        if let name = call.arguments as? String {
          UserDefaults(suiteName: "group.dev.littlelove.littlelove")?
            .set(name, forKey: "partner_name")
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

    // Native → Dart privacy channel (screenshot / screen-recording detection).
    self.callPrivacyChannel = FlutterMethodChannel(
      name: "little_love/call_privacy", binaryMessenger: messenger)

    // In-room message chimes (sent / received).
    let soundChannel = FlutterMethodChannel(
      name: "little_love/message_sounds", binaryMessenger: messenger)
    soundChannel.setMethodCallHandler { [weak self] call, result in
      guard let self = self else { return }
      switch call.method {
      case "playSent":
        let sid = self.messageSound("message_sent", cached: &self.sentSoundID)
        if sid != 0 { AudioServicesPlaySystemSound(sid) }
        result(nil)
      case "playReceived":
        let sid = self.messageSound("message_received", cached: &self.receivedSoundID)
        if sid != 0 { AudioServicesPlaySystemSound(sid) }
        result(nil)
      default:
        result(FlutterMethodNotImplemented)
      }
    }
    self.messageSoundChannel = soundChannel
  }

  /// Resolve a bundled Flutter audio asset to a registered `SystemSoundID`,
  /// caching it so the file is only loaded once.
  private func messageSound(_ name: String, cached: inout SystemSoundID) -> SystemSoundID {
    if cached != 0 { return cached }
    let key = FlutterDartProject.lookupKey(forAsset: "assets/audio/\(name).wav")
    guard let path = Bundle.main.path(forResource: key, ofType: nil) else {
      NSLog("little_love: message sound asset missing: \(name)")
      return 0
    }
    var sid: SystemSoundID = 0
    AudioServicesCreateSystemSoundID(URL(fileURLWithPath: path) as CFURL, &sid)
    cached = sid
    return sid
  }

  // MARK: - Capture privacy (screenshot + screen recording)

  /// Start watching for this device capturing the call — only while a video call
  /// is active. Screenshots can only be detected (not blocked); screen recording
  /// is reported as it starts/stops so the partner can pause their video.
  private func startCaptureObservers() {
    let nc = NotificationCenter.default
    nc.addObserver(
      self, selector: #selector(onScreenshot),
      name: UIApplication.userDidTakeScreenshotNotification, object: nil)
    nc.addObserver(
      self, selector: #selector(onCaptureChanged),
      name: UIScreen.capturedDidChangeNotification, object: nil)
    // Cover the window before iOS snapshots it for the app switcher. Observe
    // both the app- and scene-level notifications (scene apps deliver one or the
    // other depending on iOS version).
    nc.addObserver(
      self, selector: #selector(onWillResignActive),
      name: UIApplication.willResignActiveNotification, object: nil)
    nc.addObserver(
      self, selector: #selector(onDidBecomeActive),
      name: UIApplication.didBecomeActiveNotification, object: nil)
    nc.addObserver(
      self, selector: #selector(onWillResignActive),
      name: UIScene.willDeactivateNotification, object: nil)
    nc.addObserver(
      self, selector: #selector(onDidBecomeActive),
      name: UIScene.didActivateNotification, object: nil)
    // Watch for WebRTC/iOS rerouting the audio out from under us mid-call (the
    // speaker bug) so we can flip it back — see applyVideoSpeakerRoute.
    nc.addObserver(
      self, selector: #selector(onAudioRouteChange),
      name: AVAudioSession.routeChangeNotification, object: nil)
    // Report the current state immediately — recording may already be running
    // when the call connects.
    onCaptureChanged()
  }

  @objc private func onAudioRouteChange(_ note: Notification) {
    // The notification can arrive on a non-main thread; re-assert on main so the
    // RTCAudioSession lock and override are serialized with our other audio work.
    DispatchQueue.main.async { [weak self] in self?.applyVideoSpeakerRoute() }
  }

  private func stopCaptureObservers() {
    let nc = NotificationCenter.default
    nc.removeObserver(
      self, name: UIApplication.userDidTakeScreenshotNotification, object: nil)
    nc.removeObserver(
      self, name: UIScreen.capturedDidChangeNotification, object: nil)
    nc.removeObserver(
      self, name: UIApplication.willResignActiveNotification, object: nil)
    nc.removeObserver(
      self, name: UIApplication.didBecomeActiveNotification, object: nil)
    nc.removeObserver(self, name: UIScene.willDeactivateNotification, object: nil)
    nc.removeObserver(self, name: UIScene.didActivateNotification, object: nil)
    nc.removeObserver(self, name: AVAudioSession.routeChangeNotification, object: nil)
    hidePrivacyCover()
  }

  @objc private func onWillResignActive() { showPrivacyCover() }
  @objc private func onDidBecomeActive() { hidePrivacyCover() }

  private func keyWindow() -> UIWindow? {
    let windows = UIApplication.shared.connectedScenes
      .compactMap { $0 as? UIWindowScene }
      .flatMap { $0.windows }
    // Prefer the key window, but fall back to any window — at resign-active time
    // the key window can briefly be nil, which would skip the cover.
    return windows.first { $0.isKeyWindow } ?? windows.first
  }

  private func showPrivacyCover() {
    guard privacyCover == nil, let window = keyWindow() else { return }
    let cover = UIView(frame: window.bounds)
    cover.autoresizingMask = [.flexibleWidth, .flexibleHeight]
    // Opaque (not blur) so nothing of the call leaks into the snapshot.
    cover.backgroundColor = UIColor(red: 0.082, green: 0.063, blue: 0.114, alpha: 1)
    let lock = UIImageView(image: UIImage(systemName: "lock.fill"))
    lock.tintColor = UIColor.white.withAlphaComponent(0.45)
    lock.translatesAutoresizingMaskIntoConstraints = false
    cover.addSubview(lock)
    NSLayoutConstraint.activate([
      lock.centerXAnchor.constraint(equalTo: cover.centerXAnchor),
      lock.centerYAnchor.constraint(equalTo: cover.centerYAnchor),
      lock.widthAnchor.constraint(equalToConstant: 42),
      lock.heightAnchor.constraint(equalToConstant: 42),
    ])
    window.addSubview(cover)
    window.bringSubviewToFront(cover)
    privacyCover = cover
  }

  private func hidePrivacyCover() {
    privacyCover?.removeFromSuperview()
    privacyCover = nil
  }

  @objc private func onScreenshot() {
    callPrivacyChannel?.invokeMethod("localScreenshot", arguments: nil)
  }

  @objc private func onCaptureChanged() {
    callPrivacyChannel?.invokeMethod("localRecording", arguments: UIScreen.main.isCaptured)
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
    // Foundation.Data — qualified because `import flutter_callkit_incoming` also
    // brings a `Data` model type into scope, making the bare name ambiguous.
    didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Foundation.Data
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
      let data = try? Foundation.Data(contentsOf: url),
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
