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
}

/// An immutable, ready-to-render preview payload.
private struct PreviewDocument {
    let data: Data
    let type: MotionFileType
}

// MARK: - Errors

private enum PreviewError: LocalizedError {
    case emptyPath
    case unsupportedType(String)
    case unreadableFile(String)
    case missingTemplate(String)

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
        }
    }
}

// MARK: - HTML rendering

private enum HTMLRenderer {
    /// Fills the bundled template for `document` with its base64 payload.
    static func render(_ document: PreviewDocument) -> Result<String, PreviewError> {
        do {
            let template = try String(contentsOf: templateURL(for: document.type), encoding: .utf8)
            let html =
                template
                .replacingOccurrences(of: "{{BASE64_DATA}}", with: document.data.base64EncodedString())
                .replacingOccurrences(of: "{{DATA_TYPE}}", with: document.type.dataType)
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

    /// Templates live one directory above the executable, next to the bundle assets.
    private static func templateURL(for type: MotionFileType) throws -> URL {
        guard let executablePath = Bundle.main.executablePath else {
            throw PreviewError.missingTemplate(type.templateName)
        }
        return URL(fileURLWithPath: executablePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent(type.templateName)
    }
}

// MARK: - Views

private struct MotionWebView: NSViewRepresentable {
    let document: PreviewDocument

    func makeNSView(context: Context) -> WKWebView {
        let webView = WKWebView()
        let html: String
        switch HTMLRenderer.render(document) {
        case .success(let rendered): html = rendered
        case .failure(let error): html = HTMLRenderer.errorPage(error)
        }
        webView.loadHTMLString(html, baseURL: nil)
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

    let delegate = AppDelegate(document: PreviewDocument(data: data, type: fileType))

    let app = NSApplication.shared
    app.delegate = delegate
    app.setActivationPolicy(.accessory) // Run as an accessory; no Dock icon.
    app.activate(ignoringOtherApps: true)
    app.run()
}
