import Cocoa
import FlutterMacOS

@main
class AppDelegate: FlutterAppDelegate {
  // TokenBar lives in the menu bar: closing the window hides it (see
  // DesktopIntegration.onWindowClose) and the app keeps running. Quit comes from
  // the tray menu or Cmd+Q, which the Dart side handles.
  override func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
    return false
  }

  override func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
    return true
  }
}
