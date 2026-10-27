import AppKit
import SwiftUI

private struct ContentSizeKey: PreferenceKey {
    static var defaultValue: CGSize = .zero
    static func reduce(value: inout CGSize, nextValue: () -> CGSize) { value = nextValue() }
}

extension View {
    /// NSHostingView does not resize an existing borderless NSPanel by itself.
    /// Measure the ideal content height rather than the saved window's proposal.
    func fittingWindowContent(_ changed: @escaping (CGSize) -> Void) -> some View {
        fixedSize(horizontal: false, vertical: true)
            .background(GeometryReader { geometry in
                Color.clear.preference(key: ContentSizeKey.self, value: geometry.size)
            })
            .onPreferenceChange(ContentSizeKey.self, perform: changed)
    }
}

@MainActor
enum WindowContentSizing {
    static func fit(_ window: NSWindow, to size: CGSize) {
        guard size.width.isFinite, size.height.isFinite, size.width > 0, size.height > 0 else { return }
        let content = NSRect(origin: .zero, size: NSSize(width: ceil(size.width), height: ceil(size.height)))
        let needed = window.frameRect(forContentRect: content).size
        guard abs(window.frame.width - needed.width) > 0.5 || abs(window.frame.height - needed.height) > 0.5 else { return }
        let frame = NSRect(x: window.frame.minX, y: window.frame.maxY - needed.height,
                           width: needed.width, height: needed.height)
        window.setFrame(frame, display: window.isVisible)
    }
}
