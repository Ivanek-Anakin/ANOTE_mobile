import Flutter
import UIKit

@main
@objc class AppDelegate: FlutterAppDelegate {
  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    GeneratedPluginRegistrant.register(with: self)

    // Register MethodChannel for device info queries.
    let controller = window?.rootViewController as! FlutterViewController
    let channel = FlutterMethodChannel(
      name: "com.anote/device_info",
      binaryMessenger: controller.binaryMessenger
    )
    channel.setMethodCallHandler { (call, result) in
      if call.method == "getDeviceModel" {
        var systemInfo = utsname()
        uname(&systemInfo)
        let machine = withUnsafePointer(to: &systemInfo.machine) {
          $0.withMemoryRebound(to: CChar.self, capacity: 1) {
            String(cString: $0)
          }
        }
        result(machine)
      } else if call.method == "getTotalMemoryMB" {
        let totalMemory = ProcessInfo.processInfo.physicalMemory
        let memoryMB = Int(totalMemory / (1024 * 1024))
        result(memoryMB)
      } else {
        result(FlutterMethodNotImplemented)
      }
    }

    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }
}
