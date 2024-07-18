import Cocoa
import SwiftUI
import WebKit

class FloatingWindow: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}


class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    var window: FloatingWindow!
    var initialFileContent: (data: Data, isJson: Bool)?
    var eventMonitor: Any?

    func applicationDidFinishLaunching(_ aNotification: Notification) {
        print("Application did finish launching")
        
        // Create the SwiftUI view that provides the window contents.
        let contentView = ContentView(initialFileContent: initialFileContent) {
            NSApplication.shared.terminate(nil)
        }

        // Calculate the window size to cover the entire screen
        guard let screen = NSScreen.main else { return }
        let windowFrame = screen.frame

        // Create the window and set the content view.
        window = FloatingWindow(
            contentRect: windowFrame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered, defer: false)
        window.level = .floating
        window.backgroundColor = .clear
        window.isOpaque = false
        window.hasShadow = false
        window.contentView = NSHostingView(rootView: contentView)
        window.delegate = self
        
        print("Window created")

        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        
        // Set up a local event monitor for the Escape key
        eventMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { event in
            if event.keyCode == 53 { // 53 is the key code for Escape
                NSApplication.shared.terminate(nil)
                return nil
            }
            return event
        }
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        print("Application became active")
        window.makeKeyAndOrderFront(nil)
    }

    func applicationWillTerminate(_ aNotification: Notification) {
        print("Application will terminate")
        if let eventMonitor = eventMonitor {
            NSEvent.removeMonitor(eventMonitor)
        }
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
                body { margin: 0; display: flex; justify-content: center; align-items: center; height: 100vh; background-color: transparent; }
                #dotlottie-canvas { width: 100%; height: 100%; max-width: 500px; max-height: 500px; }
            </style>
        </head>
        <body>
            <canvas id="dotlottie-canvas"></canvas>
            <script type="module">
                import { DotLottie } from "https://cdn.jsdelivr.net/npm/@lottiefiles/dotlottie-web@0.28.0/+esm";

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
    let closeAction: () -> Void

    init(initialFileContent: (data: Data, isJson: Bool)?, closeAction: @escaping () -> Void) {
        self.fileContent = initialFileContent?.data ?? Data()
        self.isJson = initialFileContent?.isJson ?? true
        self.closeAction = closeAction
    }

    var body: some View {
        ZStack {
            Color.black.opacity(0.5)
                .edgesIgnoringSafeArea(.all)
                .onTapGesture {
                    closeAction()
                }
            
            WebView(fileContent: fileContent, isJson: isJson)
                .frame(width: 500, height: 500)
                .background(Color.white)
                .cornerRadius(20)
                .shadow(radius: 10)
        }
        .edgesIgnoringSafeArea(.all)
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
        
        // Activate the app but don't show it in the dock
        app.setActivationPolicy(.accessory)
        app.activate(ignoringOtherApps: true)
        
        app.run()
    }
}