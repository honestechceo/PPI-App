import Foundation
import Capacitor
import WidgetKit

// Hands the schedule to the Home Screen widget, and passes widget taps back to the app.
//  - update({ data }): data is the schedule JSON string. Refreshes the widgets.
//  - clear(): on sign-out, so the widget stops showing jobs.
//  - takeLink(): { id } of the job the widget was tapped on (once), or {}.
//  - event "open" { id } when a widget is tapped while the app is already running.
@objc(WidgetBridgePlugin)
public class WidgetBridgePlugin: CAPPlugin, CAPBridgedPlugin {
    public let identifier = "WidgetBridgePlugin"
    public let jsName = "WidgetBridge"
    public let pluginMethods: [CAPPluginMethod] = [
        CAPPluginMethod(name: "update", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "clear", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "takeLink", returnType: CAPPluginReturnPromise)
    ]
    static let openNote = Notification.Name("HTWidgetOpen")
    static var pending: String?

    // honestech://job/<id>  or  honestech://open
    static func handle(_ url: URL) -> Bool {
        guard url.scheme == "honestech" else { return false }
        let id = url.host == "job" ? url.lastPathComponent : ""
        pending = id.isEmpty ? nil : id
        NotificationCenter.default.post(name: openNote, object: nil)
        return true
    }

    override public func load() {
        NotificationCenter.default.addObserver(forName: WidgetBridgePlugin.openNote, object: nil, queue: .main) { [weak self] _ in
            guard let id = WidgetBridgePlugin.pending else { return }
            WidgetBridgePlugin.pending = nil
            self?.notifyListeners("open", data: ["id": id], retainUntilConsumed: true)
        }
    }

    @objc func update(_ call: CAPPluginCall) {
        guard let s = call.getString("data"), let d = s.data(using: .utf8),
              (try? JSONDecoder().decode(HTWidgetSnapshot.self, from: d)) != nil else {
            call.reject("bad data"); return
        }
        let ok = HTShared.write(d)
        if #available(iOS 14.0, *) { WidgetCenter.shared.reloadAllTimelines() }
        call.resolve(["ok": ok])
    }

    @objc func clear(_ call: CAPPluginCall) {
        HTShared.clear()
        if #available(iOS 14.0, *) { WidgetCenter.shared.reloadAllTimelines() }
        call.resolve(["ok": true])
    }

    @objc func takeLink(_ call: CAPPluginCall) {
        if let id = WidgetBridgePlugin.pending {
            WidgetBridgePlugin.pending = nil
            call.resolve(["id": id])
        } else {
            call.resolve([:])
        }
    }
}
