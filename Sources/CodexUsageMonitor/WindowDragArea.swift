import AppKit
import SwiftUI

/// SwiftUI hosting views consume background mouse events. A native drag surface
/// explicitly hands the original event to AppKit's cross-display window dragging.
struct WindowDragArea: NSViewRepresentable {
    func makeNSView(context: Context) -> DragView { DragView() }
    func updateNSView(_ nsView: DragView, context: Context) {}

    final class DragView: NSView {
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
        override func resetCursorRects() { addCursorRect(bounds, cursor: .openHand) }
        override func mouseDown(with event: NSEvent) {
            guard let window else { return }
            NSCursor.closedHand.push()
            window.performDrag(with: event)
            NSCursor.pop()
        }
        override func isAccessibilityElement() -> Bool { false }
    }
}
