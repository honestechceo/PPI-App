import Foundation
import LocalAuthentication
import Capacitor

// Face ID / Touch ID unlock for the iPhone app.
//  - status(): { available, kind: "faceid" | "touchid" | "opticid" | "none" }
//  - unlock({ reason }): { ok } — falls back to the phone's passcode if Face ID fails, like the Lock Screen.
@objc(BioLockPlugin)
public class BioLockPlugin: CAPPlugin, CAPBridgedPlugin {
    public let identifier = "BioLockPlugin"
    public let jsName = "BioLock"
    public let pluginMethods: [CAPPluginMethod] = [
        CAPPluginMethod(name: "status", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "unlock", returnType: CAPPluginReturnPromise)
    ]

    @objc func status(_ call: CAPPluginCall) {
        let ctx = LAContext()
        var err: NSError?
        let ok = ctx.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &err)
        var kind = "none"
        switch ctx.biometryType {
        case .faceID: kind = "faceid"
        case .touchID: kind = "touchid"
        case .none: kind = "none"
        @unknown default: kind = "opticid"
        }
        call.resolve(["available": ok, "kind": kind])
    }

    @objc func unlock(_ call: CAPPluginCall) {
        let ctx = LAContext()
        ctx.localizedCancelTitle = "Cancel"
        let reason = call.getString("reason") ?? "Unlock Honestech"
        var err: NSError?
        guard ctx.canEvaluatePolicy(.deviceOwnerAuthentication, error: &err) else {
            // no Face ID and no passcode set: nothing to check against, so don't lock the user out
            call.resolve(["ok": true, "noLock": true])
            return
        }
        ctx.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason) { ok, error in
            if ok { call.resolve(["ok": true]); return }
            let code = (error as? LAError)?.code
            call.resolve(["ok": false, "cancelled": code == .userCancel || code == .appCancel || code == .systemCancel])
        }
    }
}
