import Flutter
import UIKit
import app_links

/// This app uses the UIScene lifecycle (see `UIApplicationSceneManifest` in
/// Info.plist), so iOS delivers universal links to the **scene** delegate, not
/// `AppDelegate.application(_:continue:)`. The app_links plugin only auto-handles
/// links through the legacy app-delegate hook (`addApplicationDelegate`), which
/// iOS never calls under scenes — so without these overrides app_links never
/// sees a `/pair/<code>` link and pairing-from-a-link silently fails.
///
/// Per app_links' iOS scene setup, forward every link to
/// `AppLinks.shared.handleLink`: it buffers the first one as the initial link
/// (read by `getInitialLink()` whenever Dart is ready — no cold-launch race) and
/// emits later ones on the stream. `super` is called first so Flutter's own
/// scene wiring (window + engine registration) still runs.
class SceneDelegate: FlutterSceneDelegate {
  // Cold launch: the launching link rides in on the connection options.
  override func scene(
    _ scene: UIScene,
    willConnectTo session: UISceneSession,
    options connectionOptions: UIScene.ConnectionOptions
  ) {
    super.scene(scene, willConnectTo: session, options: connectionOptions)
    self.scene(scene, openURLContexts: connectionOptions.urlContexts)
    for userActivity in connectionOptions.userActivities {
      self.scene(scene, continue: userActivity)
    }
  }

  // Warm: a custom-scheme URL opened while the scene is connected.
  override func scene(_ scene: UIScene, openURLContexts URLContexts: Set<UIOpenURLContext>) {
    super.scene(scene, openURLContexts: URLContexts)
    for context in URLContexts {
      AppLinks.shared.handleLink(url: context.url)
    }
  }

  // Warm: a universal link opened while the scene is connected.
  override func scene(_ scene: UIScene, continue userActivity: NSUserActivity) {
    super.scene(scene, continue: userActivity)
    if let url = userActivity.webpageURL {
      AppLinks.shared.handleLink(url: url)
    }
  }
}
