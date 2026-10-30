import Foundation
import UIKit
import AVFoundation
import Vision
import Capacitor

// VIN scanner for the iPhone app.
//  - scan():      full-screen camera with a scan box. Apple's Vision reads the VIN barcode
//                 or the printed VIN text inside the box (door jamb label, windshield plate).
//  - readImage(): reads a photo the user took (barcodes + text).
// Both resolve { vin, checkOk, source } — or { cancelled: true } / { denied: true } / { vin: null }.
@objc(VinScannerPlugin)
public class VinScannerPlugin: CAPPlugin, CAPBridgedPlugin {
    public let identifier = "VinScannerPlugin"
    public let jsName = "VinScanner"
    public let pluginMethods: [CAPPluginMethod] = [
        CAPPluginMethod(name: "isAvailable", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "scan", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "readImage", returnType: CAPPluginReturnPromise)
    ]

    @objc func isAvailable(_ call: CAPPluginCall) {
        call.resolve(["available": AVCaptureDevice.default(for: .video) != nil])
    }

    @objc func scan(_ call: CAPPluginCall) {
        AVCaptureDevice.requestAccess(for: .video) { granted in
            Task { @MainActor in
                guard granted else { call.resolve(["denied": true]); return }
                guard let host = self.bridge?.viewController else { call.reject("No screen to show the scanner on"); return }
                let vc = VinCameraViewController { result in call.resolve(result) }
                vc.modalPresentationStyle = .fullScreen
                host.present(vc, animated: true)
            }
        }
    }

    @objc func readImage(_ call: CAPPluginCall) {
        guard let b64 = call.getString("data"), let data = Data(base64Encoded: b64.components(separatedBy: ",").last ?? b64),
              let img = UIImage(data: data) else {
            call.reject("Couldn't read that photo"); return
        }
        VinPhotoReader.read(img) { m in
            if let m = m { call.resolve(["vin": m.vin, "checkOk": m.checkOk, "source": m.source]) }
            else { call.resolve(["vin": NSNull()]) }
        }
    }
}

// Reads a still photo: barcodes first, then any check-digit-valid text.
enum VinPhotoReader {
    static func read(_ img: UIImage, done: @escaping (VinMatch?) -> Void) {
        guard let cg = img.cgImage else { done(nil); return }
        let orientation = CGImagePropertyOrientation(img.imageOrientation)
        DispatchQueue.global(qos: .userInitiated).async {
            var found: [(String, String)] = []
            let barcodes = VNDetectBarcodesRequest()
            barcodes.symbologies = [.code39, .code128, .dataMatrix, .qr, .pdf417]
            let text = VNRecognizeTextRequest()
            text.recognitionLevel = .accurate
            text.usesLanguageCorrection = false
            let handler = VNImageRequestHandler(cgImage: cg, orientation: orientation, options: [:])
            try? handler.perform([barcodes, text])
            for o in barcodes.results ?? [] { if let p = o.payloadStringValue { found.append((p, "barcode")) } }
            for o in text.results ?? [] { for c in o.topCandidates(3) { found.append((c.string, "text")) } }
            var best: VinMatch? = nil
            for (s, src) in found {
                guard let m = VinMatch.find(in: s, source: src) else { continue }
                if m.checkOk && (best == nil || !best!.checkOk || (src == "barcode" && best!.source != "barcode")) { best = m }
                else if best == nil && (src == "barcode" || m.labeled) { best = m }
            }
            DispatchQueue.main.async { done(best) }
        }
    }
}

// A VIN found in a barcode value or a line of text.
struct VinMatch {
    let vin: String
    let checkOk: Bool
    let source: String
    var labeled = false   // printed right after "VIN" on the label

    // Shape every real VIN has: the last 3 characters are digits, the 10th (model year) is never U, Z or 0,
    // and it has several digits. Rules out runs of label words like "MFDBYHONDADEMEXICO".
    static func plausible(_ w: [Character]) -> Bool {
        guard w[14...16].allSatisfy({ $0.isNumber }) else { return false }
        guard !["U", "Z", "0"].contains(w[9]) else { return false }
        return w.filter({ $0.isNumber }).count >= 5 && w.filter({ $0.isLetter }).count >= 2
    }

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
        source == "barcode" ? fromBarcode(raw) : fromText(raw)
    }

    // VINs never use I, O or Q: they're read-alikes of 1 and 0
    static func fix(_ c: Character) -> Character { c == "O" || c == "Q" ? "0" : (c == "I" ? "1" : c) }

    // A barcode holds just the VIN (sometimes with a leading "I" for imports): slide over it.
    static func fromBarcode(_ raw: String) -> VinMatch? {
        let chars = Array(raw.uppercased().filter { $0.isASCII && ($0.isLetter || $0.isNumber) })
        guard chars.count >= 17 else { return nil }
        var fallback: VinMatch? = nil
        for i in 0...(chars.count - 17) {
            let w = chars[i..<(i + 17)].map(fix)
            guard w.allSatisfy({ value($0) != nil }), plausible(w) else { continue }
            if checkDigitOk(w) { return VinMatch(vin: String(w), checkOk: true, source: "barcode") }
            if fallback == nil { fallback = VinMatch(vin: String(w), checkOk: false, source: "barcode") }
        }
        return fallback
    }

    // Printed text: a VIN is always one solid block of 17. Only whole words count (or two words that
    // together make 17, in case the reader split it), never pieces of label text run together.
    static func fromText(_ raw: String) -> VinMatch? {
        let words = raw.uppercased().split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == "(" || $0 == ")" || $0 == "," })
            .map { String($0.filter { $0.isASCII && ($0.isLetter || $0.isNumber) }) }.filter { !$0.isEmpty }
        var cands: [(String, Bool)] = []   // (17 characters, printed right after "VIN")
        for (n, w) in words.enumerated() {
            let afterLabel = n > 0 && ["VIN", "VINNO", "VINNUMBER"].contains(words[n - 1])
            if w.count == 17 { cands.append((w, afterLabel)) }
            for lab in ["VIN", "VINNO"] where w.hasPrefix(lab) && w.count == 17 + lab.count { cands.append((String(w.dropFirst(lab.count)), true)) }
            if n + 1 < words.count, w.count + words[n + 1].count == 17, w.count >= 5, words[n + 1].count >= 5 { cands.append((w + words[n + 1], afterLabel)) }
        }
        var fallback: VinMatch? = nil
        for (c, labeled) in cands {
            let w = Array(c).map(fix)
            guard w.allSatisfy({ value($0) != nil }), plausible(w) else { continue }
            if checkDigitOk(w) { return VinMatch(vin: String(w), checkOk: true, source: "text", labeled: labeled) }
            if labeled && fallback == nil { fallback = VinMatch(vin: String(w), checkOk: false, source: "text", labeled: true) }
        }
        return fallback
    }
}

// Runs Vision on camera frames (off the main thread) and reports VINs it reads inside the scan box.
final class VinFrameReader: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    private let lock = NSLock()
    private var roi = CGRect(x: 0.05, y: 0.35, width: 0.9, height: 0.3)   // Vision coordinates (0-1, origin bottom-left)
    private var busy = false
    private var last = Date.distantPast
    private var frame = 0
    var onMatch: (@Sendable (VinMatch) -> Void)?

    func setRegion(_ r: CGRect) { lock.lock(); roi = r; lock.unlock() }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        lock.lock()
        if busy || Date().timeIntervalSince(last) < 0.12 { lock.unlock(); return }
        busy = true; last = Date(); frame += 1
        let region = roi, n = frame
        lock.unlock()
        defer { lock.lock(); busy = false; lock.unlock() }
        guard let pixels = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }

        let barcodes = VNDetectBarcodesRequest()
        barcodes.symbologies = [.code39, .code128, .dataMatrix, .qr, .pdf417]
        barcodes.regionOfInterest = region
        var requests: [VNRequest] = [barcodes]
        // text is slower: read it on every other frame
        let text = VNRecognizeTextRequest()
        if n % 2 == 0 {
            text.recognitionLevel = .accurate
            text.usesLanguageCorrection = false
            text.regionOfInterest = region
            text.minimumTextHeight = 0.02
            requests.append(text)
        }
        // the camera's frames are sideways; .right turns them upright for a phone held in portrait
        let handler = VNImageRequestHandler(cvPixelBuffer: pixels, orientation: .right, options: [:])
        try? handler.perform(requests)
        var out: [VinMatch] = []
        for o in barcodes.results ?? [] { if let p = o.payloadStringValue, let m = VinMatch.find(in: p, source: "barcode") { out.append(m) } }
        if n % 2 == 0 {
            for o in text.results ?? [] { for c in o.topCandidates(2) { if let m = VinMatch.find(in: c.string, source: "text") { out.append(m) } } }
        }
        for m in out { onMatch?(m) }
    }
}

// The scanner screen: camera, dimmed surroundings, a scan box with corner brackets and a moving line.
final class VinCameraViewController: UIViewController, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
    private let finishWith: ([String: Any]) -> Void
    private let session = AVCaptureSession()
    private let queue = DispatchQueue(label: "vin.camera")
    private let reader = VinFrameReader()
    private var device: AVCaptureDevice?
    private var preview: AVCaptureVideoPreviewLayer!
    private let dim = CAShapeLayer()
    private let corners = CAShapeLayer()
    private let line = CALayer()
    private let hint = UILabel()
    private var finished = false
    private var seen: [String: Int] = [:]   // VINs without a valid check digit must be read 3 times

    init(finish: @escaping ([String: Any]) -> Void) {
        self.finishWith = finish
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError("not used") }

    override var prefersStatusBarHidden: Bool { true }
    override var supportedInterfaceOrientations: UIInterfaceOrientationMask { .portrait }

    // the scan box: wide and short, a little above the middle
    private var box: CGRect {
        let b = view.bounds, w = b.width - 40, h = min(130, w * 0.32)
        return CGRect(x: 20, y: b.midY - h / 2 - 60, width: w, height: h)
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        preview = AVCaptureVideoPreviewLayer(session: session)
        preview.videoGravity = .resizeAspectFill
        view.layer.addSublayer(preview)

        dim.fillRule = .evenOdd
        dim.fillColor = UIColor.black.withAlphaComponent(0.55).cgColor
        view.layer.addSublayer(dim)
        corners.strokeColor = UIColor.white.cgColor
        corners.fillColor = UIColor.clear.cgColor
        corners.lineWidth = 5
        corners.lineCap = .round
        view.layer.addSublayer(corners)
        line.backgroundColor = UIColor(red: 0.36, green: 0.85, blue: 0.85, alpha: 0.95).cgColor
        line.shadowColor = line.backgroundColor
        line.shadowOpacity = 0.9
        line.shadowRadius = 4
        line.shadowOffset = .zero
        view.layer.addSublayer(line)

        let title = UILabel()
        title.text = "SCAN VIN"
        title.textColor = .white
        let titleFont: UIFont
        if #available(iOS 16.0, *) { titleFont = .systemFont(ofSize: 20, weight: .heavy, width: .condensed) } else { titleFont = .systemFont(ofSize: 20, weight: .heavy) }
        title.attributedText = NSAttributedString(string: "SCAN VIN", attributes: [.kern: 2.0, .font: titleFont, .foregroundColor: UIColor.white])
        let close = pill("✕", action: #selector(cancelTapped), size: 20)
        let light = pill("Light", action: #selector(lightTapped), size: 17)
        hint.text = "Fit the VIN barcode or the printed VIN in the box"
        hint.textColor = .white
        hint.font = .systemFont(ofSize: 17, weight: .semibold)
        hint.textAlignment = .center
        hint.numberOfLines = 0
        hint.layer.shadowColor = UIColor.black.cgColor
        hint.layer.shadowOpacity = 0.8
        hint.layer.shadowRadius = 4
        hint.layer.shadowOffset = .zero
        let photo = UIButton(type: .system)
        photo.setTitle("Take photo instead", for: .normal)
        photo.titleLabel?.font = .systemFont(ofSize: 17, weight: .semibold)
        photo.setTitleColor(.black, for: .normal)
        photo.backgroundColor = .white
        photo.layer.cornerRadius = 12
        photo.contentEdgeInsets = UIEdgeInsets(top: 14, left: 30, bottom: 14, right: 30)
        photo.addTarget(self, action: #selector(photoTapped), for: .touchUpInside)
        for v in [title, close, light, hint, photo] as [UIView] { v.translatesAutoresizingMaskIntoConstraints = false; view.addSubview(v) }
        let g = view.safeAreaLayoutGuide
        NSLayoutConstraint.activate([
            close.topAnchor.constraint(equalTo: g.topAnchor, constant: 8),
            close.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
            close.widthAnchor.constraint(equalToConstant: 64), close.heightAnchor.constraint(equalToConstant: 48),
            light.centerYAnchor.constraint(equalTo: close.centerYAnchor),
            light.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),
            light.widthAnchor.constraint(equalToConstant: 64), light.heightAnchor.constraint(equalToConstant: 48),
            title.centerYAnchor.constraint(equalTo: close.centerYAnchor),
            title.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            photo.bottomAnchor.constraint(equalTo: g.bottomAnchor, constant: -16),
            photo.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            hint.bottomAnchor.constraint(equalTo: photo.topAnchor, constant: -14),
            hint.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 24),
            hint.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -24)
        ])

        reader.onMatch = { [weak self] m in Task { @MainActor in self?.consider(m) } }
        setUpCamera()
    }

    private func pill(_ t: String, action: Selector, size: CGFloat) -> UIButton {
        let b = UIButton(type: .system)
        b.setTitle(t, for: .normal)
        b.titleLabel?.font = .systemFont(ofSize: size, weight: .semibold)
        b.setTitleColor(.white, for: .normal)
        b.backgroundColor = UIColor.white.withAlphaComponent(0.22)
        b.layer.cornerRadius = 24
        b.addTarget(self, action: action, for: .touchUpInside)
        return b
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        preview.frame = view.bounds
        let r = box
        let p = UIBezierPath(rect: view.bounds)
        p.append(UIBezierPath(roundedRect: r, cornerRadius: 4))
        dim.path = p.cgPath
        let c = UIBezierPath(), L: CGFloat = 26, R: CGFloat = 10
        // four rounded corner brackets
        c.move(to: CGPoint(x: r.minX, y: r.minY + L)); c.addLine(to: CGPoint(x: r.minX, y: r.minY + R))
        c.addQuadCurve(to: CGPoint(x: r.minX + R, y: r.minY), controlPoint: CGPoint(x: r.minX, y: r.minY)); c.addLine(to: CGPoint(x: r.minX + L, y: r.minY))
        c.move(to: CGPoint(x: r.maxX - L, y: r.minY)); c.addLine(to: CGPoint(x: r.maxX - R, y: r.minY))
        c.addQuadCurve(to: CGPoint(x: r.maxX, y: r.minY + R), controlPoint: CGPoint(x: r.maxX, y: r.minY)); c.addLine(to: CGPoint(x: r.maxX, y: r.minY + L))
        c.move(to: CGPoint(x: r.maxX, y: r.maxY - L)); c.addLine(to: CGPoint(x: r.maxX, y: r.maxY - R))
        c.addQuadCurve(to: CGPoint(x: r.maxX - R, y: r.maxY), controlPoint: CGPoint(x: r.maxX, y: r.maxY)); c.addLine(to: CGPoint(x: r.maxX - L, y: r.maxY))
        c.move(to: CGPoint(x: r.minX + L, y: r.maxY)); c.addLine(to: CGPoint(x: r.minX + R, y: r.maxY))
        c.addQuadCurve(to: CGPoint(x: r.minX, y: r.maxY - R), controlPoint: CGPoint(x: r.minX, y: r.maxY)); c.addLine(to: CGPoint(x: r.minX, y: r.maxY - L))
        corners.path = c.cgPath
        line.frame = CGRect(x: r.minX + 24, y: r.minY + 12, width: r.width - 48, height: 2)
        line.removeAllAnimations()
        let a = CABasicAnimation(keyPath: "position.y")
        a.fromValue = r.minY + 12; a.toValue = r.maxY - 12
        a.duration = 1.4; a.autoreverses = true; a.repeatCount = .infinity
        a.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        line.add(a, forKey: "scan")
        updateRegion()
    }

    // Vision reads only what's in the box (plus a little margin), in upright-image coordinates.
    private func updateRegion() {
        guard let d = device else { return }
        let dims = CMVideoFormatDescriptionGetDimensions(d.activeFormat.formatDescription)
        let imgW = CGFloat(min(dims.width, dims.height)), imgH = CGFloat(max(dims.width, dims.height))   // upright (portrait)
        let b = view.bounds
        let scale = max(b.width / imgW, b.height / imgH)   // aspect fill
        let shownW = imgW * scale, shownH = imgH * scale
        let offX = (shownW - b.width) / 2, offY = (shownH - b.height) / 2
        let r = box.insetBy(dx: -16, dy: -28)
        var x = (r.minX + offX) / shownW, w = r.width / shownW
        var yTop = (r.minY + offY) / shownH, h = r.height / shownH
        x = max(0, x); yTop = max(0, yTop); w = min(1 - x, w); h = min(1 - yTop, h)
        reader.setRegion(CGRect(x: x, y: 1 - yTop - h, width: w, height: h))
    }

    private func setUpCamera() {
        // A multi-camera device lets the phone switch to its close-focus lens on its own (Pro iPhones can't focus close with the main lens).
        let types: [AVCaptureDevice.DeviceType] = [.builtInTripleCamera, .builtInDualWideCamera, .builtInDualCamera, .builtInWideAngleCamera]
        let found = AVCaptureDevice.DiscoverySession(deviceTypes: types, mediaType: .video, position: .back).devices
        guard let dev = types.lazy.compactMap({ t in found.first(where: { $0.deviceType == t }) }).first ?? AVCaptureDevice.default(for: .video),
              let input = try? AVCaptureDeviceInput(device: dev) else {
            hint.text = "The camera isn't available. Tap Take photo instead."
            return
        }
        device = dev
        session.beginConfiguration()
        session.sessionPreset = session.canSetSessionPreset(.hd1920x1080) ? .hd1920x1080 : .high
        if session.canAddInput(input) { session.addInput(input) }
        let out = AVCaptureVideoDataOutput()
        out.alwaysDiscardsLateVideoFrames = true
        out.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange]
        out.setSampleBufferDelegate(reader, queue: DispatchQueue(label: "vin.frames"))
        if session.canAddOutput(out) { session.addOutput(out) }
        session.commitConfiguration()

        do {
            try dev.lockForConfiguration()
            if dev.isFocusModeSupported(.continuousAutoFocus) { dev.focusMode = .continuousAutoFocus }
            if dev.isAutoFocusRangeRestrictionSupported { dev.autoFocusRangeRestriction = .near }
            if dev.isSmoothAutoFocusSupported { dev.isSmoothAutoFocusEnabled = false }
            // Multi-camera devices start on the ultra-wide lens: begin at the main lens ("1x"); near a label the
            // phone switches to its close-focus (macro) lens by itself.
            let base = dev.virtualDeviceSwitchOverVideoZoomFactors.first.map { CGFloat(truncating: $0) } ?? 1
            let macro = dev.deviceType == .builtInTripleCamera || dev.deviceType == .builtInDualWideCamera
            // Apple's recommended zoom for close-up codes: if the lens can't focus as close as the label
            // needs to be to fill the box, zoom in so the label can be held farther away and stay sharp.
            var extra: CGFloat = 1
            let minFocusMM = Float(dev.minimumFocusDistance)
            if minFocusMM > 0 {
                let dims = CMVideoFormatDescriptionGetDimensions(dev.activeFormat.formatDescription)
                let wide = dev.activeFormat.videoFieldOfView * .pi / 180
                // across the phone held upright = the sensor's short side
                let fov = 2 * atan(tan(wide / 2) * Float(min(dims.width, dims.height)) / Float(max(dims.width, dims.height)))
                let labelMM: Float = 60, fill: Float = 0.8
                let needMM = (labelMM / fill) / 2 / tan(fov / 2)
                if needMM < minFocusMM { extra = CGFloat(minFocusMM / needMM) }
            }
            extra = min(extra, macro ? 1.5 : 3)
            dev.videoZoomFactor = max(dev.minAvailableVideoZoomFactor, min(base * extra, dev.activeFormat.videoMaxZoomFactor))
            dev.unlockForConfiguration()
        } catch {}
        queue.async { [session] in session.startRunning() }
    }

    private func consider(_ m: VinMatch) {
        guard !finished else { return }
        if m.checkOk { win(m); return }
        // No valid check digit (e.g. European VINs): only from the barcode or text printed right after "VIN",
        // and only once it reads the same 3 times
        guard m.source == "barcode" || m.labeled else { return }
        seen[m.vin, default: 0] += 1
        if seen[m.vin]! >= 3 { win(m) }
    }

    private func win(_ m: VinMatch) {
        corners.strokeColor = UIColor.systemGreen.cgColor
        line.isHidden = true
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        hint.text = m.vin
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
            self?.finish(["vin": m.vin, "checkOk": m.checkOk, "source": m.source])
        }
    }

    private func finish(_ result: [String: Any]) {
        guard !finished else { return }
        finished = true
        setTorch(false)
        reader.onMatch = nil
        queue.async { [session] in session.stopRunning() }
        dismiss(animated: true) { self.finishWith(result) }
    }

    @objc private func cancelTapped() { finish(["cancelled": true]) }

    @objc private func lightTapped() { setTorch(device?.torchMode != .on) }

    private func setTorch(_ on: Bool) {
        guard let d = device, d.hasTorch else { return }
        do { try d.lockForConfiguration(); d.torchMode = on ? .on : .off; d.unlockForConfiguration() } catch {}
    }

    // "Take photo instead": the phone's camera, then the same reader on the still photo
    @objc private func photoTapped() {
        guard UIImagePickerController.isSourceTypeAvailable(.camera) else { return }
        setTorch(false)
        queue.async { [session] in session.stopRunning() }
        let p = UIImagePickerController()
        p.sourceType = .camera
        p.delegate = self
        present(p, animated: true)
    }

    func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
        picker.dismiss(animated: true)
        queue.async { [session] in session.startRunning() }
    }

    func imagePickerController(_ picker: UIImagePickerController, didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
        picker.dismiss(animated: true)
        guard let img = info[.originalImage] as? UIImage else { return }
        hint.text = "Reading the photo…"
        VinPhotoReader.read(img) { [weak self] m in
            guard let self = self else { return }
            if let m = m { self.win(m) }
            else {
                self.hint.text = "No VIN found in that photo. Get closer so the VIN fills more of the picture, or try again."
                self.queue.async { [session = self.session] in session.startRunning() }
            }
        }
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
