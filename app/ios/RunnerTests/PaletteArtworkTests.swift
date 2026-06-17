import XCTest

@testable import Runner

final class PaletteArtworkTests: XCTestCase {
  func testKnownKeyResolvesToItsAsset() {
    XCTAssertEqual(PaletteArtwork.resolve(forKey: "twilight"), "twilight")
  }

  func testUnknownKeyFallsBackToDefault() {
    XCTAssertEqual(
      PaletteArtwork.resolve(forKey: "midnight-future-palette"), PaletteArtwork.defaultAsset)
  }

  func testNilKeyFallsBackToDefault() {
    XCTAssertEqual(PaletteArtwork.resolve(forKey: nil), PaletteArtwork.defaultAsset)
  }

  func testEmptyKeyFallsBackToDefault() {
    XCTAssertEqual(PaletteArtwork.resolve(forKey: ""), PaletteArtwork.defaultAsset)
  }
}
