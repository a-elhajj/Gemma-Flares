import Flutter
import UIKit

class SceneDelegate: FlutterSceneDelegate {
	override func scene(
		_ scene: UIScene,
		willConnectTo session: UISceneSession,
		options connectionOptions: UIScene.ConnectionOptions
	) {
		super.scene(scene, willConnectTo: session, options: connectionOptions)

			if let flutterViewController = window?.rootViewController as? FlutterViewController {
				HealthKitBridge.register(with: flutterViewController.binaryMessenger)
				SystemStatusBridge.register(with: flutterViewController.binaryMessenger)
				LabTextRecognitionBridge.register(
					with: flutterViewController.binaryMessenger,
					presenter: flutterViewController
			)
		}
	}
}
