import UIKit
import Capacitor

// The app's main screen. Registers the plugins that live in this app (not in npm packages).
class MainViewController: CAPBridgeViewController {
    override func capacitorDidLoad() {
        bridge?.registerPluginInstance(VinScannerPlugin())
    }
}
