import Cocoa
import SwiftUI
import WebKit

class ForegroundWindow: NSWindow {
    override var canBecomeKey: Bool {
        return true
    }

    override var canBecomeMain: Bool {
        return true
    }
}

class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    var window: ForegroundWindow!
    var initialFileContent: (data: Data, isJson: Bool)?

    func applicationDidFinishLaunching(_ aNotification: Notification) {
        print("Application did finish launching")
        
        // Create the SwiftUI view that provides the window contents.
        let contentView = ContentView(initialFileContent: initialFileContent)

        // Calculate the window size
        let windowWidth: CGFloat = 600
        let windowHeight: CGFloat = 600

        // Create the window and set the content view.
        window = ForegroundWindow(
            contentRect: NSRect(x: 0, y: 0, width: windowWidth, height: windowHeight),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered, defer: false)
        window.title = "Raycast Lottie Preview"
        window.contentView = NSHostingView(rootView: contentView)
        window.delegate = self
        
        centerWindow()
        
        print("Window created and centered")

        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func centerWindow() {
        guard let screen = NSScreen.main else { return }
        let screenFrame = screen.visibleFrame
        let windowFrame = window.frame
        let newOriginX = screenFrame.midX - windowFrame.width / 2
        let newOriginY = screenFrame.midY - windowFrame.height / 2
        let newOrigin = CGPoint(x: newOriginX, y: newOriginY)
        window.setFrameOrigin(newOrigin)
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        print("Application became active")
        window.makeKeyAndOrderFront(nil)
    }

    func applicationWillTerminate(_ aNotification: Notification) {
        print("Application will terminate")
    }

    func windowWillClose(_ notification: Notification) {
        print("Window will close")
        NSApplication.shared.terminate(self)
    }
}

struct WebView: NSViewRepresentable {
    var fileContent: Data
    var isJson: Bool

    func makeNSView(context: Context) -> WKWebView {
        let webView = WKWebView()
        webView.loadHTMLString(htmlContent, baseURL: nil)
        return webView
    }

    func updateNSView(_ nsView: WKWebView, context: Context) {
        nsView.loadHTMLString(htmlContent, baseURL: nil)
    }

    private var htmlContent: String {
        let base64Data = fileContent.base64EncodedString()
        let dataType = isJson ? "json" : "arraybuffer"
        
        return """
        <html>
        <head>
            <style>
                body { margin: 0; display: flex; justify-content: center; align-items: center; height: 100vh; background-color: #f0f0f0; }
                #dotlottie-canvas { width: 100%; height: 100%; max-width: 500px; max-height: 500px; }
            </style>
        </head>
        <body>
            <canvas id="dotlottie-canvas"></canvas>
            <script type="module">
                import { DotLottie } from "https://esm.sh/@lottiefiles/dotlottie-web";

                const canvas = document.getElementById('dotlottie-canvas');
                const base64Data = "\(base64Data)";
                const binaryString = atob(base64Data);
                const len = binaryString.length;
                const bytes = new Uint8Array(len);
                for (let i = 0; i < len; i++) {
                    bytes[i] = binaryString.charCodeAt(i);
                }
                const data = "\(dataType)" === "json" ? JSON.parse(new TextDecoder().decode(bytes)) : bytes.buffer;

                new DotLottie({
                    canvas,
                    data,
                    loop: true,
                    autoplay: true
                });
            </script>
        </body>
        </html>
        """
    }
}

struct ContentView: View {
    let fileContent: Data
    let isJson: Bool

    init(initialFileContent: (data: Data, isJson: Bool)?) {
        self.fileContent = initialFileContent?.data ?? Data()
        self.isJson = initialFileContent?.isJson ?? true
    }

    var body: some View {
        WebView(fileContent: fileContent, isJson: isJson)
            .frame(width: 500, height: 500)
    }
}

@main
struct MainApp {
    static func main() {
        let delegate = AppDelegate()
        
        if CommandLine.arguments.count > 1 {
            let filePath = CommandLine.arguments[1]
            if let fileContent = try? Data(contentsOf: URL(fileURLWithPath: filePath)) {
                let isJson = filePath.lowercased().hasSuffix(".json")
                delegate.initialFileContent = (fileContent, isJson)
                print("File loaded successfully")
            } else {
                print("Failed to load file")
            }
        } else {
            print("No file path provided")
        }
        
        let app = NSApplication.shared
        app.delegate = delegate
        
        // Activate the app and show it in the dock
        app.setActivationPolicy(.regular)
        app.activate(ignoringOtherApps: true)
        
        app.run()
    }
}