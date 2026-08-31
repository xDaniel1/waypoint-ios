import CarPlay
import UIKit

/// The entry point for the car screen. iOS creates this scene alongside (or instead of) the phone
/// window when the device connects to a CarPlay head unit, and tears it down on disconnect.
///
/// Named in `Info.plist` under `UIApplicationSceneManifest` as
/// `$(PRODUCT_MODULE_NAME).CarPlaySceneDelegate`, which is why the class is `@objc`-visible.
final class CarPlaySceneDelegate: UIResponder, CPTemplateApplicationSceneDelegate {
    private var controller: CarPlayController?
    private var mapViewController: CarPlayMapViewController?

    func templateApplicationScene(
        _ templateApplicationScene: CPTemplateApplicationScene,
        didConnect interfaceController: CPInterfaceController,
        to window: CPWindow
    ) {
        let mapViewController = CarPlayMapViewController()
        window.rootViewController = mapViewController
        self.mapViewController = mapViewController
        controller = CarPlayController(
            interfaceController: interfaceController,
            mapViewController: mapViewController
        )
    }

    func templateApplicationScene(
        _ templateApplicationScene: CPTemplateApplicationScene,
        didDisconnectInterfaceController interfaceController: CPInterfaceController,
        from window: CPWindow
    ) {
        controller = nil
        mapViewController = nil
    }

    /// The car tells us which part of the screen its own panels aren't covering; the map insets
    /// itself by that so the route and the car's position stay clear of the guidance card.
    func templateApplicationScene(
        _ templateApplicationScene: CPTemplateApplicationScene,
        didChangeSafeAreaInsets insets: UIEdgeInsets
    ) {
        controller?.updateSafeArea(insets)
    }
}
