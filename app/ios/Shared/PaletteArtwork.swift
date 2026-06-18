import Foundation

/// Maps a palette key (written by the app into the shared App Group) to the
/// bundled artwork asset name the Notification Service Extension attaches.
/// Pure and dependency-free so it is unit-testable in isolation. Today only
/// `twilight` ships; future palettes add a case here + an asset.
enum PaletteArtwork {
  static let appGroupId = "group.dev.littlelove.littlelove"
  static let paletteDefaultsKey = "selected_palette"
  static let defaultAsset = "twilight"

  /// Resolve a palette key to an asset name. Unknown / missing keys fall back
  /// to the default — never crash, never return empty.
  static func resolve(forKey key: String?) -> String {
    switch key {
    case "twilight":
      return "twilight"
    default:
      return defaultAsset
    }
  }
}
