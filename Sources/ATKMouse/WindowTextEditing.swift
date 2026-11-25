import AppKit
import SwiftUI

/// End editing before delivering an outside click to the rest of this window.
struct WindowTextEditing: NSViewRepresentable {
    func makeNSView(context: Context) -> Observer { Observer(frame: .zero) }
    func updateNSView(_ nsView: Observer, context: Context) {}

    final class Observer: NSView {
        private var monitor: Any?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            stopMonitoring()
            guard window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown, .keyDown]) {
                [weak self] event in
                guard let self else { return event }
                return self.handle(event)
            }
        }

        deinit { stopMonitoring() }

        private func stopMonitoring() {
            if let monitor {
                NSEvent.removeMonitor(monitor)
                self.monitor = nil
            }
        }

        private func handle(_ event: NSEvent) -> NSEvent? {
            guard let window, event.window === window,
                  let editor = window.firstResponder as? NSTextView, editor.isFieldEditor,
                  let field = editor.delegate as? NSTextField else { return event }
            if event.type == .keyDown {
                if event.charactersIgnoringModifiers == "\u{1b}", window.makeFirstResponder(nil) {
                    return nil
                }
            } else if !field.bounds.contains(field.convert(event.locationInWindow, from: nil)) {
                window.makeFirstResponder(nil)
            }
            return event
        }
    }
}
