import UIKit
import UserNotifications

/// Runs on each incoming push (the server sets `mutable-content: 1`). Reads the
/// currently-selected palette from the shared App Group and attaches the
/// matching bundled artwork. On any failure it delivers the original content
/// unchanged (graceful degradation — the push still shows as plain text).
class NotificationService: UNNotificationServiceExtension {
  var contentHandler: ((UNNotificationContent) -> Void)?
  var bestAttempt: UNMutableNotificationContent?

  override func didReceive(
    _ request: UNNotificationRequest,
    withContentHandler contentHandler: @escaping (UNNotificationContent) -> Void
  ) {
    self.contentHandler = contentHandler
    let mutable = request.content.mutableCopy() as? UNMutableNotificationContent
    self.bestAttempt = mutable
    guard let content = mutable else {
      contentHandler(request.content)
      return
    }

    let defaults = UserDefaults(suiteName: PaletteArtwork.appGroupId)
    let key = defaults?.string(forKey: PaletteArtwork.paletteDefaultsKey)
    let asset = PaletteArtwork.resolve(forKey: key)

    if let attachment = Self.attachment(named: asset) {
      content.attachments = [attachment]
    }
    contentHandler(content)
  }

  override func serviceExtensionTimeWillExpire() {
    if let handler = contentHandler, let content = bestAttempt {
      handler(content)
    }
  }

  /// Build a notification attachment from a bundled image asset. Returns nil on
  /// any failure so the caller falls back to the plain notification.
  private static func attachment(named asset: String) -> UNNotificationAttachment? {
    guard let image = UIImage(named: asset),
      let data = image.pngData()
    else { return nil }
    let dir = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    do {
      try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
      let url = dir.appendingPathComponent("\(asset).png")
      try data.write(to: url)
      return try UNNotificationAttachment(identifier: asset, url: url, options: nil)
    } catch {
      return nil
    }
  }
}
