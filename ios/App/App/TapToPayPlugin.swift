import Foundation
import UIKit
import Capacitor
import StripeTerminal
import ProximityReader

// Tap to Pay on iPhone through Stripe Terminal, on each shop's own Stripe account (direct charges).
// The web app does the server calls (it holds the sign-in); this plugin only talks to Stripe Terminal and Apple.
//  - status(): { supported, reason, connected, initialized, ios }
//  - connect({ locationId, merchant, tos }): connects the built-in reader. The first time on an Apple Account the owner
//    accepts Apple's terms (tos must be true; techs pass false and get "not accepted yet").
//    Events while connecting: "progress" { stage: "installing" | "installed", progress }.
//  - collect({ clientSecret }): shows Apple's Tap to Pay screen, then confirms. Resolves { status, id, brand, last4 }.
//    Events: "message" { text }, "input" { text }.
//  - cancel(): stops a running collect.
//  - howToTap(): Apple's "How to Tap" education (iOS 18+); resolves { shown }.
//  - token({ secret } | { error }): the web app's answer to a "token" event (Stripe asks for a connection token).
//  Errors reject with code = the Stripe error number as a string (e.g. "3930" terms not accepted) and a plain message.
@objc(TapToPayPlugin)
public class TapToPayPlugin: CAPPlugin, CAPBridgedPlugin, ConnectionTokenProvider, TapToPayReaderDelegate {
    public let identifier = "TapToPayPlugin"
    public let jsName = "TapToPay"
    public let pluginMethods: [CAPPluginMethod] = [
        CAPPluginMethod(name: "status", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "connect", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "collect", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "cancel", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "howToTap", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "token", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "disconnect", returnType: CAPPluginReturnPromise)
    ]

    private var tokenWaiters: [ConnectionTokenCompletionBlock] = []
    private var discoverCancel: Cancelable?
    private var collectCancel: Cancelable?
    private var connecting = false
    private var finder: OneShot?   // Terminal doesn't keep the discovery delegate alive

    private func ensureInit() {
        if !Terminal.isInitialized() { Terminal.initWithTokenProvider(self) }
    }

    // MARK: connection tokens (asked of the web app, which calls the server with the signed-in user)
    public func fetchConnectionToken(_ completion: @escaping ConnectionTokenCompletionBlock) {
        DispatchQueue.main.async {
            self.tokenWaiters.append(completion)
            self.notifyListeners("token", data: [:])
            // don't hang forever if the web view never answers
            DispatchQueue.main.asyncAfter(deadline: .now() + 25) {
                guard !self.tokenWaiters.isEmpty else { return }
                let w = self.tokenWaiters; self.tokenWaiters = []
                w.forEach { $0(nil, NSError(domain: "TapToPay", code: 1, userInfo: [NSLocalizedDescriptionKey: "Couldn't reach the server. Check your signal."])) }
            }
        }
    }

    @objc func token(_ call: CAPPluginCall) {
        DispatchQueue.main.async {
            let w = self.tokenWaiters; self.tokenWaiters = []
            if let s = call.getString("secret"), !s.isEmpty { w.forEach { $0(s, nil) } }
            else {
                let msg = call.getString("error") ?? "Couldn't get ready for Tap to Pay."
                w.forEach { $0(nil, NSError(domain: "TapToPay", code: 2, userInfo: [NSLocalizedDescriptionKey: msg])) }
            }
            call.resolve()
        }
    }

    // MARK: status
    @objc func status(_ call: CAPPluginCall) {
        DispatchQueue.main.async {
            self.ensureInit()
            var supported = false, reason = ""
            switch Terminal.shared.supportsReaders(of: .tapToPay, discoveryMethod: .tapToPay, simulated: false) {
            case .success: supported = true
            case .failure(let error): reason = Self.plain(error)
            }
            let t = Terminal.shared
            call.resolve(["supported": supported, "reason": reason,
                          "connected": t.connectedReader?.deviceType == .tapToPay,
                          "initialized": true, "ios": UIDevice.current.systemVersion])
        }
    }

    // MARK: connect (also the "warm up": the web app calls it on launch and when the app comes back)
    @objc func connect(_ call: CAPPluginCall) {
        guard let loc = call.getString("locationId"), !loc.isEmpty else { call.reject("missing location", "missing"); return }
        DispatchQueue.main.async {
            self.ensureInit()
            if Terminal.shared.connectedReader?.deviceType == .tapToPay { call.resolve(["connected": true, "already": true]); return }
            if self.connecting { call.reject("Already getting ready. Try again in a moment.", "busy"); return }
            self.connecting = true
            let disc: TapToPayDiscoveryConfiguration
            do { disc = try TapToPayDiscoveryConfigurationBuilder().setSimulated(false).build() }
            catch { self.connecting = false; self.fail(call, error); return }
            var done = false
            let finder = OneShot { readers in
                guard !done, let reader = readers.first else { return }
                done = true
                let cfg: TapToPayConnectionConfiguration
                do {
                    cfg = try TapToPayConnectionConfigurationBuilder(delegate: self, locationId: loc)
                        .setMerchantDisplayName(call.getString("merchant"))
                        .setTosAcceptancePermitted(call.getBool("tos") ?? false)
                        .setAutoReconnectOnUnexpectedDisconnect(true)
                        .build()
                } catch { self.connecting = false; self.fail(call, error); return }
                Terminal.shared.connectReader(reader, connectionConfig: cfg) { r, err in
                    DispatchQueue.main.async {
                        self.connecting = false
                        if let err = err { self.fail(call, err); return }
                        call.resolve(["connected": r != nil])
                    }
                }
            }
            self.finder = finder
            self.discoverCancel = Terminal.shared.discoverReaders(disc, delegate: finder) { err in
                DispatchQueue.main.async {
                    self.finder = nil
                    if let err = err, !done { done = true; self.connecting = false; self.fail(call, err) }
                }
            }
        }
    }

    @objc func disconnect(_ call: CAPPluginCall) {
        DispatchQueue.main.async {
            guard Terminal.isInitialized(), Terminal.shared.connectedReader != nil else { call.resolve(); return }
            Terminal.shared.disconnectReader { _ in call.resolve() }
        }
    }

    // MARK: collect + confirm one payment
    @objc func collect(_ call: CAPPluginCall) {
        guard let secret = call.getString("clientSecret"), !secret.isEmpty else { call.reject("missing payment", "missing"); return }
        DispatchQueue.main.async {
            self.ensureInit()
            guard Terminal.shared.connectedReader?.deviceType == .tapToPay else { call.reject("Tap to Pay isn't ready yet.", "notready"); return }
            Terminal.shared.retrievePaymentIntent(clientSecret: secret) { pi, err in
                guard let pi = pi else { self.fail(call, err); return }
                DispatchQueue.main.async {
                    self.collectCancel = Terminal.shared.collectPaymentMethod(pi) { collected, err in
                        DispatchQueue.main.async {
                            self.collectCancel = nil
                            guard let collected = collected else { self.fail(call, err); return }
                            Terminal.shared.confirmPaymentIntent(collected) { done, cerr in
                                DispatchQueue.main.async {
                                    if let cerr = cerr { self.fail(call, cerr); return }
                                    guard let done = done else { call.reject("The payment didn't finish.", "unknown"); return }
                                    var out: [String: Any] = ["id": done.stripeId ?? "", "status": done.status == .succeeded ? "succeeded" : "processing",
                                                              "amount": Double(done.amount) / 100.0]
                                    if let cp = done.paymentMethod?.cardPresent {
                                        out["brand"] = cp.brand
                                        out["last4"] = cp.last4 ?? ""
                                    }
                                    call.resolve(out)
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    @objc func cancel(_ call: CAPPluginCall) {
        DispatchQueue.main.async {
            guard let c = self.collectCancel else { call.resolve(["canceled": false]); return }
            c.cancel { _ in call.resolve(["canceled": true]) }
        }
    }

    // MARK: Apple's "How to Tap" education
    @objc func howToTap(_ call: CAPPluginCall) {
        guard #available(iOS 18.0, *) else { call.resolve(["shown": false]); return }
        Task { @MainActor in
            do {
                let discovery = ProximityReaderDiscovery()
                let content = try await discovery.content(for: .payment(.howToTap))
                guard var top = self.bridge?.viewController else { call.resolve(["shown": false]); return }
                while let p = top.presentedViewController { top = p }
                try await discovery.presentContent(content, from: top)
                call.resolve(["shown": true])
            } catch {
                call.resolve(["shown": false, "error": error.localizedDescription])
            }
        }
    }

    // MARK: reader events
    public func reader(_ reader: Reader, didStartInstallingUpdate update: ReaderSoftwareUpdate, cancelable: Cancelable?) {
        notifyListeners("progress", data: ["stage": "installing", "progress": 0])
    }
    public func reader(_ reader: Reader, didReportReaderSoftwareUpdateProgress progress: Float) {
        notifyListeners("progress", data: ["stage": "installing", "progress": Double(progress)])
    }
    public func reader(_ reader: Reader, didFinishInstallingUpdate update: ReaderSoftwareUpdate?, error: Error?) {
        notifyListeners("progress", data: ["stage": "installed", "progress": 1, "error": error.map { Self.plain($0) } ?? ""])
    }
    public func reader(_ reader: Reader, didRequestReaderInput inputOptions: ReaderInputOptions) {
        notifyListeners("input", data: ["text": Terminal.stringFromReaderInputOptions(inputOptions)])
    }
    public func reader(_ reader: Reader, didRequestReaderDisplayMessage displayMessage: ReaderDisplayMessage) {
        notifyListeners("message", data: ["text": Terminal.stringFromReaderDisplayMessage(displayMessage)])
    }
    public func tapToPayReaderDidAcceptTermsOfService(_ reader: Reader) {
        notifyListeners("tos", data: ["accepted": true], retainUntilConsumed: true)
    }
    public func reader(_ reader: Reader, didDisconnect reason: DisconnectReason) {
        notifyListeners("disconnected", data: [:])
    }

    // MARK: errors in plain words
    private func fail(_ call: CAPPluginCall, _ error: Error?) {
        let e = (error ?? NSError(domain: "TapToPay", code: 0)) as NSError
        call.reject(Self.plain(e), String(e.code), e)
    }
    static func plain(_ error: Error) -> String {
        let e = error as NSError
        if e.domain == "TapToPay" { return e.localizedDescription }
        switch e.code {
        case 2020, 2021: return "Payment canceled."
        case 3930: return "Tap to Pay on iPhone isn't turned on for this Apple Account yet. The owner turns it on in Settings."
        case 2960: return "Sign in to iCloud on this iPhone (Settings → your name), then try again."
        case 2970: return "Apple's terms weren't accepted, so Tap to Pay on iPhone is still off."
        case 3920: return "Apple has blocked Tap to Pay on this iPhone."
        case 3950, 3960, 3970: return "Apple won't take payments for this business right now. Check your Stripe account."
        case 2910: return "This iPhone can't use Tap to Pay. It needs an iPhone XS or newer on the latest iOS, with a passcode set."
        case 3850, 1870: return "Update iOS (Settings → General → Software Update), then try again."
        default: return e.localizedDescription
        }
    }
}

// a discovery delegate that hands the first list of readers to a closure
private class OneShot: NSObject, DiscoveryDelegate {
    let got: ([Reader]) -> Void
    init(_ got: @escaping ([Reader]) -> Void) { self.got = got }
    func terminal(_ terminal: Terminal, didUpdateDiscoveredReaders readers: [Reader]) { got(readers) }
}
