import Flutter
import Darwin
import UIKit

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
  }
}

final class SystemStatusBridge: NSObject {
  static let channelName = "com.gemma_flares/system_status"

  static func register(with messenger: FlutterBinaryMessenger) {
    let channel = FlutterMethodChannel(name: channelName, binaryMessenger: messenger)
    let instance = SystemStatusBridge()
    channel.setMethodCallHandler(instance.handle)
  }

  private func handle(call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case "getSystemStatus":
      result([
        "lowPowerModeEnabled": ProcessInfo.processInfo.isLowPowerModeEnabled,
        "thermalState": Self.thermalStateLabel(ProcessInfo.processInfo.thermalState),
        "availableMemoryBytes": Self.availableMemoryBytes(),
        "backgroundRefreshStatus": Self.backgroundRefreshStatusLabel(
          UIApplication.shared.backgroundRefreshStatus
        ),
      ])
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  private static func thermalStateLabel(_ state: ProcessInfo.ThermalState) -> String {
    switch state {
    case .nominal:
      return "nominal"
    case .fair:
      return "fair"
    case .serious:
      return "serious"
    case .critical:
      return "critical"
    @unknown default:
      return "unknown"
    }
  }

  private static func backgroundRefreshStatusLabel(
    _ status: UIBackgroundRefreshStatus
  ) -> String {
    switch status {
    case .available:
      return "available"
    case .denied:
      return "denied"
    case .restricted:
      return "restricted"
    @unknown default:
      return "unknown"
    }
  }

  private static func availableMemoryBytes() -> UInt64 {
    if #available(iOS 13.0, *) {
      return UInt64(os_proc_available_memory())
    }
    return 0
  }
}
