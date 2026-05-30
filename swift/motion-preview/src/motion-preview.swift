import Cocoa
import RaycastSwiftMacros
import SwiftUI
import WebKit

// MARK: - Model

// A motion file format the previewer can render, along with the template, data marker, and MIME type it needs.
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

    var templateName: String {
        switch self {
        case .rive: "preview_rive.html"
        case .lottieJSON, .dotLottie: "preview_lottie.html"
        }
    }

    var dataType: String {
        switch self {
        case .rive: "arraybuffer"
        case .lottieJSON: "json"
        case .dotLottie: "lottie"
        }
    }

    var dataMimeType: String {
        switch self {
        case .lottieJSON: "application/json"
        case .rive, .dotLottie: "application/octet-stream"
        }
    }
}

// An immutable, ready-to-render preview payload.
private struct PreviewDocument {
    let data: Data
    let type: MotionFileType
}

// MARK: - Errors

// Failures surfaced to the user; `description` keeps the Raycast bridge's stderr output human-readable.
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

    var description: String { errorDescription ?? "Unable to preview the file." }
}

// MARK: - Lottie validation

// Validates a Lottie document's required top-level fields up front, so a bad file surfaces as a message rather than a blank window.
private enum LottieValidator {
    static func validate(_ data: Data) throws {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw PreviewError.invalidLottie("not a JSON object")
        }

        guard let version = object["v"] as? String, version.first?.isNumber == true else {
            throw PreviewError.invalidLottie(#"missing or invalid "v""#)
        }

        try requirePositive(object, "fr")
        try requireNonNegative(object, "ip")
        try requireNonNegative(object, "op")
        try requirePositiveInteger(object, "w")
        try requirePositiveInteger(object, "h")
    }

    // Reads a numeric field, rejecting JSON booleans (which also bridge to NSNumber).
    private static func number(_ object: [String: Any], _ key: String) -> Double? {
        guard let value = object[key] as? NSNumber else { return nil }
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

// Locates the assets directory (HTML templates and the vendored `lib/` runtime), two levels above the executable.
private enum BundleLayout {
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

// Fills the bundled template with the document's data-type marker; the payload is fetched separately via the scheme handler.
private enum HTMLRenderer {
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

    // A standalone page shown when a template can't load, so a render failure surfaces in the window instead of crashing.
    static func errorPage(_ error: PreviewError) -> String {
        let message = (error.errorDescription ?? "Unable to render preview.")
            .replacingOccurrences(of: "<", with: "&lt;")
        return """
        <!doctype html>
        <html>
          <head><meta charset="utf-8"></head>
          <body style="margin:0;height:100vh;display:flex;align-items:center;justify-content:center;\
        background:#fff;font-family:-apple-system,Arial,sans-serif;color:#333;text-align:center;padding:24px;box-sizing:border-box;">
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

// Serves the page, the vendored runtime, and the raw animation bytes from one in-process origin (motion://app/), giving
// the page a real origin so it can fetch its payload and load the renderer locally — fully offline, with no base64 inlining.
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

    // Maps a motion://app/<path> request to bytes: the rendered page, the animation payload (/data), or a vendored
    // `lib/` asset — rejecting any path that tries to traverse out of the assets directory.
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

// Hosts a transparent WKWebView that loads the preview page from the custom scheme, so the page's stage color (or none) shows through to the window; falls back to the error page if assets are missing.
private struct MotionWebView: NSViewRepresentable {
    let document: PreviewDocument

    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()

        guard let assetsDirectory = try? BundleLayout.assetsDirectory() else {
            let webView = WKWebView(frame: .zero, configuration: configuration)
            let error = PreviewError.missingTemplate(document.type.templateName)
            webView.loadHTMLString(HTMLRenderer.errorPage(error), baseURL: nil)
            return webView
        }

        let handler = PreviewSchemeHandler(document: document, assetsDirectory: assetsDirectory)
        configuration.setURLSchemeHandler(handler, forURLScheme: PreviewSchemeHandler.scheme)

        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.setValue(false, forKey: "drawsBackground")
        if let baseURL = PreviewSchemeHandler.baseURL {
            webView.load(URLRequest(url: baseURL))
        }
        return webView
    }

    func updateNSView(_ nsView: WKWebView, context: Context) {}
}

// The framed animation card centered over a dimmed, click-to-dismiss backdrop.
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
                .cornerRadius(20)
                .shadow(radius: 10)
        }
        .ignoresSafeArea()
    }
}

// MARK: - Window & app lifecycle

// A borderless floating panel that can still become key, so it receives the Escape key.
private final class PreviewWindow: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

// Builds and shows the floating preview window, and tears the app down on close or Escape (key code 53).
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

        escapeMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { [weak self] event in
            guard event.keyCode == 53 else { return event }
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

// Validates the path and file type, reads the bytes, validates Lottie JSON up front, then runs the accessory app (no Dock icon) that shows the window.
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

    if case .lottieJSON = fileType {
        try LottieValidator.validate(data)
    }

    let delegate = AppDelegate(document: PreviewDocument(data: data, type: fileType))

    let app = NSApplication.shared
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    app.activate(ignoringOtherApps: true)
    app.run()
}
