import Cocoa
import RaycastSwiftMacros
import SwiftUI
import WebKit

// MARK: - Model

/// A motion file format the previewer knows how to render.
private enum MotionFileType {
    case rive
    case lottieJSON
    case dotLottie

    init?(fileExtension: String) {
        switch fileExtension.lowercased() {
        case "riv": self = .rive
        case "json": self = .lottieJSON
        case "lottie": self = .dotLottie
        default: return nil
        }
    }

    /// HTML template bundled alongside the executable.
    var templateName: String {
        switch self {
        case .rive: "preview_rive.html"
        case .lottieJSON, .dotLottie: "preview_lottie.html"
        }
    }

    /// Value substituted for the template's `{{DATA_TYPE}}` placeholder.
    var dataType: String {
        switch self {
        case .rive: "arraybuffer"
        case .lottieJSON: "json"
        case .dotLottie: "lottie"
        }
    }

    /// MIME type used when the scheme handler serves the raw payload to the page.
    var dataMimeType: String {
        switch self {
        case .lottieJSON: "application/json"
        case .rive, .dotLottie: "application/octet-stream"
        }
    }
}

/// An immutable, ready-to-render preview payload.
private struct PreviewDocument {
    let data: Data
    let type: MotionFileType
}

// MARK: - Errors

private enum PreviewError: LocalizedError, CustomStringConvertible {
    case emptyPath
    case unsupportedType(String)
    case unreadableFile(String)
    case missingTemplate(String)
    case invalidLottie(String)

    var errorDescription: String? {
        switch self {
        case .emptyPath:
            "No file path was provided."
        case .unsupportedType(let ext):
            "Unsupported file type: .\(ext)"
        case .unreadableFile(let path):
            "Could not read file at \(path)."
        case .missingTemplate(let name):
            "Could not load preview template \(name)."
        case .invalidLottie(let reason):
            "Invalid Lottie JSON file (\(reason))."
        }
    }

    // When the entry point rethrows, the Raycast bridge prints the error to
    // stderr; this keeps that output human-readable instead of the raw enum case.
    var description: String { errorDescription ?? "Unable to preview the file." }
}

// MARK: - Lottie validation

private enum LottieValidator {
    /// A Lottie animation must be a JSON object carrying these correctly-typed
    /// top-level properties. Validating here means the file is read once (the
    /// previewer already loaded its bytes) instead of being re-read and
    /// re-parsed by a separate JavaScript pre-flight.
    static func validate(_ data: Data) throws {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw PreviewError.invalidLottie("not a JSON object")
        }

        // `v`: version string beginning with a digit.
        guard let version = object["v"] as? String, version.first?.isNumber == true else {
            throw PreviewError.invalidLottie(#"missing or invalid "v""#)
        }

        try requirePositive(object, "fr") // frame rate > 0
        try requireNonNegative(object, "ip") // in point >= 0
        try requireNonNegative(object, "op") // out point >= 0
        try requirePositiveInteger(object, "w") // width
        try requirePositiveInteger(object, "h") // height
    }

    private static func number(_ object: [String: Any], _ key: String) -> Double? {
        guard let value = object[key] as? NSNumber else { return nil }
        // Reject JSON booleans, which also bridge to NSNumber.
        if CFGetTypeID(value) == CFBooleanGetTypeID() { return nil }
        return value.doubleValue
    }

    private static func requirePositive(_ object: [String: Any], _ key: String) throws {
        guard let value = number(object, key), value > 0 else {
            throw PreviewError.invalidLottie("missing or invalid \"\(key)\"")
        }
    }

    private static func requireNonNegative(_ object: [String: Any], _ key: String) throws {
        guard let value = number(object, key), value >= 0 else {
            throw PreviewError.invalidLottie("missing or invalid \"\(key)\"")
        }
    }

    private static func requirePositiveInteger(_ object: [String: Any], _ key: String) throws {
        guard let value = number(object, key), value > 0, value.truncatingRemainder(dividingBy: 1) == 0 else {
            throw PreviewError.invalidLottie("missing or invalid \"\(key)\"")
        }
    }
}

// MARK: - Bundle layout

private enum BundleLayout {
    /// Assets (the HTML templates and the vendored `lib/` runtime) live two
    /// directories above the executable, next to the bundle assets.
    static func assetsDirectory() throws -> URL {
        guard let executablePath = Bundle.main.executablePath else {
            throw PreviewError.missingTemplate("assets")
        }
        return URL(fileURLWithPath: executablePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }
}

// MARK: - HTML rendering

private enum HTMLRenderer {
    /// Fills the bundled template for `document` with its data-type marker. The
    /// payload itself is no longer inlined; the page fetches it from the scheme
    /// handler, avoiding a base64 round-trip and several large in-memory copies.
    static func render(_ document: PreviewDocument) -> Result<String, PreviewError> {
        do {
            let template = try String(contentsOf: templateURL(for: document.type), encoding: .utf8)
            let html = template.replacingOccurrences(of: "{{DATA_TYPE}}", with: document.type.dataType)
            return .success(html)
        } catch let error as PreviewError {
            return .failure(error)
        } catch {
            return .failure(.missingTemplate(document.type.templateName))
        }
    }

    /// A standalone page shown when a template can't be loaded, so a render
    /// failure surfaces in the window instead of crashing the process.
    static func errorPage(_ error: PreviewError) -> String {
        let message = (error.errorDescription ?? "Unable to render preview.")
            .replacingOccurrences(of: "<", with: "&lt;")
        return """
        <!doctype html>
        <html>
          <head><meta charset="utf-8"></head>
          <body style="margin:0;height:100vh;display:flex;align-items:center;justify-content:center;\
        font-family:-apple-system,Arial,sans-serif;color:#333;text-align:center;padding:24px;box-sizing:border-box;">
            <p>\(message)</p>
          </body>
        </html>
        """
    }

    private static func templateURL(for type: MotionFileType) throws -> URL {
        try BundleLayout.assetsDirectory().appendingPathComponent(type.templateName)
    }
}

// MARK: - Custom scheme handler

/// Serves the preview page, the vendored runtime, and the raw animation bytes
/// from a single in-process origin (`motion://app/`). Giving the page a real
/// origin lets it `fetch()` its payload and load the renderer/WASM locally —
/// no CDN round-trip, no base64 inlining, and it works fully offline.
private final class PreviewSchemeHandler: NSObject, WKURLSchemeHandler {
    static let scheme = "motion"
    static let baseURL = URL(string: "\(scheme)://app/index.html")

    private let document: PreviewDocument
    private let assetsDirectory: URL

    init(document: PreviewDocument, assetsDirectory: URL) {
        self.document = document
        self.assetsDirectory = assetsDirectory
    }

    func webView(_ webView: WKWebView, start task: WKURLSchemeTask) {
        guard let url = task.request.url, let payload = payload(for: url) else {
            task.didFailWithError(URLError(.unsupportedURL))
            return
        }

        guard let response = HTTPURLResponse(
            url: url,
            statusCode: 200,
            httpVersion: "HTTP/1.1",
            headerFields: [
                "Content-Type": payload.mimeType,
                "Content-Length": String(payload.data.count),
                "Cache-Control": "no-store",
                "Access-Control-Allow-Origin": "*",
            ]
        ) else {
            task.didFailWithError(URLError(.badServerResponse))
            return
        }

        task.didReceive(response)
        task.didReceive(payload.data)
        task.didFinish()
    }

    func webView(_ webView: WKWebView, stop task: WKURLSchemeTask) {}

    /// Maps a `motion://app/<path>` request to bytes: the rendered page, the
    /// animation payload (`/data`), or a vendored runtime asset (`/lib/...`).
    private func payload(for url: URL) -> (data: Data, mimeType: String)? {
        switch url.path {
        case "", "/", "/index.html":
            let html: String
            switch HTMLRenderer.render(document) {
            case .success(let rendered): html = rendered
            case .failure(let error): html = HTMLRenderer.errorPage(error)
            }
            return (Data(html.utf8), "text/html; charset=utf-8")

        case "/data":
            return (document.data, document.type.dataMimeType)

        default:
            // Anything else must be a vendored file under `lib/`. Reject paths
            // that try to escape the assets directory.
            let relativePath = String(url.path.drop(while: { $0 == "/" }))
            guard relativePath.hasPrefix("lib/"), !relativePath.contains("..") else { return nil }

            let fileURL = assetsDirectory.appendingPathComponent(relativePath)
            guard let data = try? Data(contentsOf: fileURL) else { return nil }
            return (data, Self.mimeType(forPathExtension: fileURL.pathExtension))
        }
    }

    private static func mimeType(forPathExtension ext: String) -> String {
        switch ext.lowercased() {
        case "js": "text/javascript"
        case "wasm": "application/wasm"
        case "json": "application/json"
        default: "application/octet-stream"
        }
    }
}

// MARK: - Views

private struct MotionWebView: NSViewRepresentable {
    let document: PreviewDocument

    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()

        guard let assetsDirectory = try? BundleLayout.assetsDirectory() else {
            // Without the assets directory we can't serve the runtime; show the
            // error page directly so the window isn't blank.
            let webView = WKWebView(frame: .zero, configuration: configuration)
            let error = PreviewError.missingTemplate(document.type.templateName)
            webView.loadHTMLString(HTMLRenderer.errorPage(error), baseURL: nil)
            return webView
        }

        let handler = PreviewSchemeHandler(document: document, assetsDirectory: assetsDirectory)
        configuration.setURLSchemeHandler(handler, forURLScheme: PreviewSchemeHandler.scheme)

        let webView = WKWebView(frame: .zero, configuration: configuration)
        if let baseURL = PreviewSchemeHandler.baseURL {
            webView.load(URLRequest(url: baseURL))
        }
        return webView
    }

    // The document is immutable, so there is nothing to reload after the initial load.
    func updateNSView(_ nsView: WKWebView, context: Context) {}
}

private struct ContentView: View {
    let document: PreviewDocument
    let onClose: () -> Void

    var body: some View {
        ZStack {
            Color.black.opacity(0.5)
                .ignoresSafeArea()
                .onTapGesture(perform: onClose)

            MotionWebView(document: document)
                .frame(width: 550, height: 550)
                .background(Color.white)
                .cornerRadius(20)
                .shadow(radius: 10)
        }
        .ignoresSafeArea()
    }
}

// MARK: - Window & app lifecycle

private final class PreviewWindow: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

private final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private let document: PreviewDocument
    private var window: PreviewWindow?
    private var escapeMonitor: Any?

    init(document: PreviewDocument) {
        self.document = document
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let contentView = ContentView(document: document) { [weak self] in
            self?.terminate()
        }

        let frame = NSScreen.main?.frame ?? NSRect(x: 0, y: 0, width: 800, height: 600)
        let window = PreviewWindow(
            contentRect: frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        window.level = .floating
        window.backgroundColor = .clear
        window.isOpaque = false
        window.hasShadow = false
        window.contentView = NSHostingView(rootView: contentView)
        window.delegate = self
        self.window = window

        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        // Dismiss on Escape.
        escapeMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { [weak self] event in
            guard event.keyCode == 53 else { return event } // 53 == Escape
            self?.terminate()
            return nil
        }
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        window?.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        terminate()
    }

    private func terminate() {
        if let escapeMonitor {
            NSEvent.removeMonitor(escapeMonitor)
            self.escapeMonitor = nil
        }
        NSApplication.shared.terminate(nil)
    }
}

// MARK: - Raycast entry point

@raycast func previewFile(filePath: String) throws {
    guard !filePath.isEmpty else {
        throw PreviewError.emptyPath
    }

    let fileExtension = (filePath as NSString).pathExtension
    guard let fileType = MotionFileType(fileExtension: fileExtension) else {
        throw PreviewError.unsupportedType(fileExtension)
    }

    guard let data = try? Data(contentsOf: URL(fileURLWithPath: filePath)) else {
        throw PreviewError.unreadableFile(filePath)
    }

    // Validate Lottie JSON up front so a bad file surfaces as a message instead
    // of an empty preview window. Binary formats (.riv, .lottie) are left to the
    // renderer.
    if case .lottieJSON = fileType {
        try LottieValidator.validate(data)
    }

    let delegate = AppDelegate(document: PreviewDocument(data: data, type: fileType))

    let app = NSApplication.shared
    app.delegate = delegate
    app.setActivationPolicy(.accessory) // Run as an accessory; no Dock icon.
    app.activate(ignoringOtherApps: true)
    app.run()
}
