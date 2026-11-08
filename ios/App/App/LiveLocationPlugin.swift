import Foundation
import Capacitor
import CoreLocation

// Live location for "On my way": keeps sending the tech's position while they drive, even with
// Apple Maps or Google Maps in front (iOS shows the blue location pill while it runs).
// It posts straight to the server with the trip's own key, so it doesn't depend on the web view being awake.
//  - start({ url, code, key, every }): begin a trip. every = seconds between updates (default 15).
//  - stop(): end it here (the app tells the server separately).
//  - status(): { on, code, auth } auth = "always" | "inuse" | "denied" | "notyet"
//  - event "loc" { lat, lng, at } after each update is sent; event "ended" { state } when the server says the trip is over.
@objc(LiveLocationPlugin)
public class LiveLocationPlugin: CAPPlugin, CAPBridgedPlugin, CLLocationManagerDelegate {
    public let identifier = "LiveLocationPlugin"
    public let jsName = "LiveLocation"
    public let pluginMethods: [CAPPluginMethod] = [
        CAPPluginMethod(name: "start", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "stop", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "status", returnType: CAPPluginReturnPromise)
    ]

    private var mgr: CLLocationManager?
    private var url: URL?
    private var code = ""
    private var key = ""
    private var every: TimeInterval = 15
    private var lastSent: Date = .distantPast
    private var lastLoc: CLLocation?
    private var sending = false
    private var pendingStart: CAPPluginCall?
    private var bgTask: UIBackgroundTaskIdentifier = .invalid

    private func authName(_ m: CLLocationManager) -> String {
        let s: CLAuthorizationStatus
        if #available(iOS 14.0, *) { s = m.authorizationStatus } else { s = CLLocationManager.authorizationStatus() }
        switch s {
        case .authorizedAlways: return "always"
        case .authorizedWhenInUse: return "inuse"
        case .denied, .restricted: return "denied"
        default: return "notyet"
        }
    }

    @objc func status(_ call: CAPPluginCall) {
        DispatchQueue.main.async {
            let m = self.mgr ?? CLLocationManager()
            call.resolve(["on": self.mgr != nil && !self.code.isEmpty, "code": self.code, "auth": self.authName(m)])
        }
    }

    @objc func start(_ call: CAPPluginCall) {
        guard let u = call.getString("url").flatMap(URL.init(string:)), let c = call.getString("code"), let k = call.getString("key"), !c.isEmpty, !k.isEmpty else {
            call.reject("missing url/code/key"); return
        }
        DispatchQueue.main.async {
            self.url = u; self.code = c; self.key = k
            self.every = max(5, call.getDouble("every") ?? 15)
            self.lastSent = .distantPast; self.lastLoc = nil
            let m = self.mgr ?? CLLocationManager()
            m.delegate = self
            m.desiredAccuracy = kCLLocationAccuracyBest
            m.distanceFilter = 25
            m.activityType = .automotiveNavigation
            m.pausesLocationUpdatesAutomatically = false
            self.mgr = m
            switch self.authName(m) {
            case "denied":
                call.reject("Location is off for Honestech. Turn it on in Settings > Honestech > Location.")
                return
            case "notyet":
                self.pendingStart = call
                m.requestWhenInUseAuthorization()
            default:
                self.begin(m)
                call.resolve(["ok": true, "auth": self.authName(m)])
            }
        }
    }

    private func begin(_ m: CLLocationManager) {
        // keep going in the background while the tech drives (needs the "location" background mode)
        m.allowsBackgroundLocationUpdates = true
        m.showsBackgroundLocationIndicator = true
        m.startUpdatingLocation()
    }

    public func locationManagerDidChangeAuthorization(_ m: CLLocationManager) { authChanged(m) }
    public func locationManager(_ m: CLLocationManager, didChangeAuthorization status: CLAuthorizationStatus) { authChanged(m) }
    private func authChanged(_ m: CLLocationManager) {
        guard let call = pendingStart else { return }
        let a = authName(m)
        if a == "notyet" { return }
        pendingStart = nil
        if a == "denied" { call.reject("Location is off for Honestech. Turn it on in Settings > Honestech > Location."); finish(); return }
        begin(m)
        call.resolve(["ok": true, "auth": a])
    }

    @objc func stop(_ call: CAPPluginCall) {
        DispatchQueue.main.async { self.finish(); call.resolve(["ok": true]) }
    }

    private func finish() {
        mgr?.stopUpdatingLocation()
        mgr?.allowsBackgroundLocationUpdates = false
        mgr?.delegate = nil
        mgr = nil
        code = ""; key = ""; pendingStart = nil
    }

    public func locationManager(_ m: CLLocationManager, didUpdateLocations locs: [CLLocation]) {
        guard let loc = locs.last, loc.horizontalAccuracy >= 0, loc.horizontalAccuracy < 500, !code.isEmpty else { return }
        let moved = lastLoc.map { loc.distance(from: $0) } ?? .infinity
        // every N seconds, sooner after a big move; never more than once every 4 seconds
        let since = Date().timeIntervalSince(lastSent)
        if sending || since < 4 || (since < every && moved < 300) { return }
        send(loc)
    }

    public func locationManager(_ m: CLLocationManager, didFailWithError error: Error) {
        print("LiveLocation error: \(error.localizedDescription)")
    }

    private func send(_ loc: CLLocation) {
        guard let url = url else { return }
        sending = true; lastSent = Date(); lastLoc = loc
        var body: [String: Any] = ["op": "loc", "code": code, "key": key,
                                   "lat": loc.coordinate.latitude, "lng": loc.coordinate.longitude, "acc": loc.horizontalAccuracy]
        if loc.course >= 0 { body["hdg"] = loc.course }
        if loc.speed >= 0 { body["spd"] = loc.speed }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)
        req.timeoutInterval = 20
        // a little background time so the request finishes if iOS is about to suspend us
        bgTask = UIApplication.shared.beginBackgroundTask(withName: "LiveLocation") { [weak self] in
            if let t = self?.bgTask, t != .invalid { UIApplication.shared.endBackgroundTask(t) }
            self?.bgTask = .invalid
        }
        let sentCode = code
        URLSession.shared.dataTask(with: req) { [weak self] data, _, _ in
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.sending = false
                if self.bgTask != .invalid { UIApplication.shared.endBackgroundTask(self.bgTask); self.bgTask = .invalid }
                guard sentCode == self.code else { return }
                var state = ""
                if let d = data, let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any] { state = o["state"] as? String ?? "" }
                self.notifyListeners("loc", data: ["lat": loc.coordinate.latitude, "lng": loc.coordinate.longitude, "at": Date().timeIntervalSince1970 * 1000, "state": state])
                if state == "arrived" || state == "stopped" {
                    self.finish()
                    self.notifyListeners("ended", data: ["state": state], retainUntilConsumed: true)
                }
            }
        }.resume()
    }
}
