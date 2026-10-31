import UIKit

// No @main here: main.m owns main() and hands the class name to UIApplicationMain.
// @objc(AppDelegate) keeps the runtime name unprefixed so that string lookup works.
@objc(AppDelegate)
class AppDelegate: UIResponder, UIApplicationDelegate {
    var window: UIWindow?

    func application(_ application: UIApplication, configurationForConnecting connectingSceneSession: UISceneSession, options: UIScene.ConnectionOptions) -> UISceneConfiguration {
        return UISceneConfiguration(name: "Default Configuration", sessionRole: connectingSceneSession.role)
    }

    func application(_ application: UIApplication, didDiscardSceneSessions sceneSessions: Set<UISceneSession>) {
    }

    func applicationWillTerminate(_ application: UIApplication) {
        // Releases the group main_hook.m waits on after a fatal exit
        leaveFatalExitGroup()
    }
}
