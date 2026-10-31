import UIKit

// Info.plist refers to this class as "SceneExternalDelegate" (the external display scene),
// so it needs the unprefixed runtime name.
@objc(SceneExternalDelegate)
class SceneExternalDelegate: UIResponder, UIWindowSceneDelegate {
    // UIWindow.externalWindow (UIKit+hook.m) only holds this weakly, keep it alive here
    var window: UIWindow?

    func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options connectionOptions: UIScene.ConnectionOptions) {
        guard let windowScene = scene as? UIWindowScene else { return }

        let window = UIWindow(windowScene: windowScene)
        window.frame = windowScene.coordinateSpace.bounds
        self.window = window
        setExternalWindow(window)

        if SurfaceViewController.isRunning && getPrefBool("video.fullscreen_airplay") {
            (UIWindow.main()?.rootViewController as? SurfaceViewController)?.switchToExternalDisplay()
        }
    }

    func sceneDidDisconnect(_ scene: UIScene) {
        if SurfaceViewController.isRunning && getPrefBool("video.fullscreen_airplay") {
            (UIWindow.main()?.rootViewController as? SurfaceViewController)?.switchToInternalDisplay()
        }
    }
}
