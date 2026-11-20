import Flutter
import UIKit

class SceneDelegate: FlutterSceneDelegate {
  override func scene(_ scene: UIScene, openURLContexts URLContexts: Set<UIOpenURLContext>) {
    guard let url = URLContexts.first?.url else { return }
    (UIApplication.shared.delegate as? AppDelegate)?.handleIncomingURL(url)
  }

  override func scene(_ scene: UIScene, continue userActivity: NSUserActivity) {
    if userActivity.activityType == NSUserActivityTypeBrowsingWeb,
       let webpageURL = userActivity.webpageURL {
      (UIApplication.shared.delegate as? AppDelegate)?.handleIncomingURL(webpageURL)
      return
    }
    super.scene(scene, continue: userActivity)
  }

  override func scene(
    _ scene: UIScene,
    willConnectTo session: UISceneSession,
    options connectionOptions: UIScene.ConnectionOptions
  ) {
    super.scene(scene, willConnectTo: session, options: connectionOptions)
    if let url = connectionOptions.urlContexts.first?.url {
      (UIApplication.shared.delegate as? AppDelegate)?.handleIncomingURL(url)
    } else if let webpageURL = connectionOptions.userActivities
      .first(where: { $0.activityType == NSUserActivityTypeBrowsingWeb })?
      .webpageURL {
      (UIApplication.shared.delegate as? AppDelegate)?.handleIncomingURL(webpageURL)
    }
  }
}
