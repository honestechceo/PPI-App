import Foundation
import UIKit
import AVFoundation
import Vision
import VisionKit
import Capacitor

// VIN scanner for the iPhone app, using Apple's own readers:
//  - scan():      live camera with Live Text (VisionKit DataScanner, iPhone XS and newer, iOS 16+).
//                 Reads the VIN barcode AND the printed VIN text (door jamb label, windshield plate).
//  - readImage(): a photo the user took; Vision finds barcodes and text in it (any iPhone).
// Both return { vin, checkOk, source } or { cancelled: true } / { vin: null }.
@objc(VinScannerPlugin)
public class VinScannerPlugin: CAPPlugin, CAPBridgedPlugin {
    public let identifier = "VinScannerPlugin"
    public let jsName = "VinScanner"
    public let pluginMethods: [CAPPluginMethod] = [
        CAPPluginMethod(name: "isAvailable", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "scan", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "readImage", returnType: CAPPluginReturnPromise)
    ]
    private var live: AnyObject?   // keeps the live scanner session alive while it's on screen

    @objc func isAvailable(_ call: CAPPluginCall) {
        Task { @MainActor in
            if #available(iOS 16.0, *) {
                call.resolve(["available": DataScannerViewController.isSupported])
            } else {
                call.resolve(["available": false])
            }
        }
    }

    @objc func scan(_ call: CAPPluginCall) {
        guard #available(iOS 16.0, *) else { call.resolve(["available": false]); return }
        AVCaptureDevice.requestAccess(for: .video) { granted in
            Task { @MainActor in
                guard DataScannerViewController.isSupported else { call.resolve(["available": false]); return }
                guard granted else { call.resolve(["denied": true]); return }
                guard DataScannerViewController.isAvailable else { call.resolve(["available": false]); return }
                guard let host = self.bridge?.viewController else { call.reject("No screen to show the scanner on"); return }
                let session = LiveVinScan(call: call) { [weak self] in self?.live = nil }
                self.live = session
                session.present(on: host)
            }
        }
    }

    @objc func readImage(_ call: CAPPluginCall) {
        guard let b64 = call.getString("data"), let data = Data(base64Encoded: b64.components(separatedBy: ",").last ?? b64),
              let img = UIImage(data: data), let cg = img.cgImage else {
            call.reject("Couldn't read that photo"); return
        }
        let orientation = CGImagePropertyOrientation(img.imageOrientation)
        DispatchQueue.global(qos: .userInitiated).async {
            var found: [(String, String)] = []   // (text, source)
            let barcodes = VNDetectBarcodesRequest()
            barcodes.symbologies = [.code39, .code128, .dataMatrix, .qr, .pdf417]
            let text = VNRecognizeTextRequest()
            text.recognitionLevel = .accurate
            text.usesLanguageCorrection = false
            let handler = VNImageRequestHandler(cgImage: cg, orientation: orientation, options: [:])
            try? handler.perform([barcodes, text])
            for o in barcodes.results ?? [] { if let p = o.payloadStringValue { found.append((p, "barcode")) } }
            for o in text.results ?? [] { for c in o.topCandidates(3) { found.append((c.string, "text")) } }
            // barcode first, then any check-digit-valid text, then a barcode without a valid check digit
            var best: VinMatch? = nil
            for (s, src) in found {
                guard let m = VinMatch.find(in: s, source: src) else { continue }
                if m.checkOk && (best == nil || !best!.checkOk || (src == "barcode" && best!.source != "barcode")) { best = m }
                else if best == nil && src == "barcode" { best = m }
            }
            DispatchQueue.main.async {
                if let b = best { call.resolve(["vin": b.vin, "checkOk": b.checkOk, "source": b.source]) }
                else { call.resolve(["vin": NSNull()]) }
            }
        }
    }
}

// A VIN found in a barcode value or a line of text.
struct VinMatch {
    let vin: String
    let checkOk: Bool
    let source: String

    static let weights = [8, 7, 6, 5, 4, 3, 2, 10, 0, 9, 8, 7, 6, 5, 4, 3, 2]
    static func value(_ c: Character) -> Int? {
        if let d = c.wholeNumberValue { return d }
        let map: [Character: Int] = ["A": 1, "B": 2, "C": 3, "D": 4, "E": 5, "F": 6, "G": 7, "H": 8, "J": 1, "K": 2, "L": 3, "M": 4,
                                     "N": 5, "P": 7, "R": 9, "S": 2, "T": 3, "U": 4, "V": 5, "W": 6, "X": 7, "Y": 8, "Z": 9]
        return map[c]
    }
    static func checkDigitOk(_ v: [Character]) -> Bool {
        var sum = 0
        for (i, c) in v.enumerated() { guard let n = value(c) else { return false }; sum += n * weights[i] }
        let r = sum % 11
        return v[8] == (r == 10 ? "X" : Character(String(r)))
    }
    static func find(in raw: String, source: String) -> VinMatch? {
        let up = raw.uppercased().filter { $0.isASCII && ($0.isLetter || $0.isNumber) }
        let chars = Array(up)
        guard chars.count >= 17 else { return nil }
        var fallback: VinMatch? = nil
        for i in 0...(chars.count - 17) {
            // VINs never use I, O or Q: they're read-alikes of 1 and 0
            let w = chars[i..<(i + 17)].map { c -> Character in c == "O" || c == "Q" ? "0" : (c == "I" ? "1" : c) }
            guard w.allSatisfy({ value($0) != nil }) else { continue }
            guard w[0...10].contains(where: { $0.isLetter }) else { continue }   // must look like a VIN, not a long number
            if checkDigitOk(w) { return VinMatch(vin: String(w), checkOk: true, source: source) }
            if fallback == nil { fallback = VinMatch(vin: String(w), checkOk: false, source: source) }
        }
        return fallback
    }
}

@available(iOS 16.0, *)
@MainActor
final class LiveVinScan: NSObject, DataScannerViewControllerDelegate {
    private let call: CAPPluginCall
    private let done: () -> Void
    private var scanner: DataScannerViewController?
    private var finished = false
    private var seen: [String: Int] = [:]   // VINs without a valid check digit must be read 3 times

    init(call: CAPPluginCall, done: @escaping () -> Void) { self.call = call; self.done = done }

    func present(on host: UIViewController) {
        let s = DataScannerViewController(
            recognizedDataTypes: [.barcode(symbologies: [.code39, .code128, .dataMatrix, .qr, .pdf417]), .text()],
            qualityLevel: .accurate, recognizesMultipleItems: true, isHighFrameRateTrackingEnabled: false,
            isPinchToZoomEnabled: true, isGuidanceEnabled: false, isHighlightingEnabled: true)
        s.delegate = self
        s.modalPresentationStyle = .fullScreen
        addOverlay(to: s)
        scanner = s
        host.present(s, animated: true) { try? s.startScanning() }
    }

    private func addOverlay(to s: DataScannerViewController) {
        let v = s.overlayContainerView
        let hint = UILabel()
        hint.text = "Point at the VIN on the door jamb label or windshield. It fills in by itself."
        hint.numberOfLines = 0
        hint.textAlignment = .center
        hint.textColor = .white
        hint.font = .systemFont(ofSize: 16, weight: .semibold)
        hint.backgroundColor = UIColor.black.withAlphaComponent(0.55)
        hint.layer.cornerRadius = 12
        hint.clipsToBounds = true
        hint.translatesAutoresizingMaskIntoConstraints = false
        let cancel = UIButton(type: .system)
        cancel.setTitle("Cancel", for: .normal)
        cancel.titleLabel?.font = .systemFont(ofSize: 18, weight: .semibold)
        cancel.tintColor = .white
        cancel.backgroundColor = UIColor.black.withAlphaComponent(0.55)
        cancel.layer.cornerRadius = 22
        cancel.contentEdgeInsets = UIEdgeInsets(top: 10, left: 22, bottom: 10, right: 22)
        cancel.translatesAutoresizingMaskIntoConstraints = false
        cancel.addTarget(self, action: #selector(cancelTapped), for: .touchUpInside)
        let light = UIButton(type: .system)
        light.setTitle("Light", for: .normal)
        light.titleLabel?.font = .systemFont(ofSize: 18, weight: .semibold)
        light.tintColor = .white
        light.backgroundColor = UIColor.black.withAlphaComponent(0.55)
        light.layer.cornerRadius = 22
        light.contentEdgeInsets = UIEdgeInsets(top: 10, left: 22, bottom: 10, right: 22)
        light.translatesAutoresizingMaskIntoConstraints = false
        light.addTarget(self, action: #selector(lightTapped), for: .touchUpInside)
        v.addSubview(hint); v.addSubview(cancel); v.addSubview(light)
        let g = v.safeAreaLayoutGuide
        NSLayoutConstraint.activate([
            cancel.topAnchor.constraint(equalTo: g.topAnchor, constant: 12),
            cancel.leadingAnchor.constraint(equalTo: g.leadingAnchor, constant: 16),
            light.topAnchor.constraint(equalTo: g.topAnchor, constant: 12),
            light.trailingAnchor.constraint(equalTo: g.trailingAnchor, constant: -16),
            hint.bottomAnchor.constraint(equalTo: g.bottomAnchor, constant: -24),
            hint.leadingAnchor.constraint(equalTo: g.leadingAnchor, constant: 20),
            hint.trailingAnchor.constraint(equalTo: g.trailingAnchor, constant: -20),
            hint.heightAnchor.constraint(greaterThanOrEqualToConstant: 64)
        ])
    }

    @objc private func cancelTapped() { finish(["cancelled": true]) }

    @objc private func lightTapped() {
        guard let dev = AVCaptureDevice.default(for: .video), dev.hasTorch else { return }
        do { try dev.lockForConfiguration(); dev.torchMode = dev.torchMode == .on ? .off : .on; dev.unlockForConfiguration() } catch {}
    }

    private func consider(_ items: [RecognizedItem]) {
        guard !finished else { return }
        var candidates: [VinMatch] = []
        for item in items {
            switch item {
            case .barcode(let b): if let p = b.payloadStringValue, let m = VinMatch.find(in: p, source: "barcode") { candidates.append(m) }
            case .text(let t): if let m = VinMatch.find(in: t.transcript, source: "text") { candidates.append(m) }
            @unknown default: break
            }
        }
        if let ok = candidates.first(where: { $0.checkOk }) { win(ok); return }
        for m in candidates {
            seen[m.vin, default: 0] += 1
            if seen[m.vin]! >= 3 { win(m); return }   // e.g. European VINs, which have no check digit
        }
    }

    private func win(_ m: VinMatch) {
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        finish(["vin": m.vin, "checkOk": m.checkOk, "source": m.source])
    }

    private func finish(_ result: [String: Any]) {
        guard !finished else { return }
        finished = true
        if let dev = AVCaptureDevice.default(for: .video), dev.hasTorch, dev.torchMode == .on {
            try? dev.lockForConfiguration(); dev.torchMode = .off; dev.unlockForConfiguration()
        }
        scanner?.stopScanning()
        scanner?.dismiss(animated: true)
        call.resolve(result)
        done()
    }

    func dataScanner(_ dataScanner: DataScannerViewController, didAdd addedItems: [RecognizedItem], allItems: [RecognizedItem]) { consider(allItems) }
    func dataScanner(_ dataScanner: DataScannerViewController, didUpdate updatedItems: [RecognizedItem], allItems: [RecognizedItem]) { consider(allItems) }
    func dataScanner(_ dataScanner: DataScannerViewController, didTapOn item: RecognizedItem) { consider([item]) }
    func dataScanner(_ dataScanner: DataScannerViewController, becameUnavailableWithError error: DataScannerViewController.ScanningUnavailable) {
        finish(["available": false])
    }
}

extension CGImagePropertyOrientation {
    init(_ o: UIImage.Orientation) {
        switch o {
        case .up: self = .up
        case .upMirrored: self = .upMirrored
        case .down: self = .down
        case .downMirrored: self = .downMirrored
        case .left: self = .left
        case .leftMirrored: self = .leftMirrored
        case .right: self = .right
        case .rightMirrored: self = .rightMirrored
        @unknown default: self = .up
        }
    }
}
