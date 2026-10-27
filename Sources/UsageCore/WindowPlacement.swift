import Foundation
import CoreGraphics

public enum WindowPlacement {
    /// Read the absolute frame from AppKit's existing autosave format without its
    /// screen-relative remapping, which can move a valid window to another monitor.
    public static func restoredFrame(from saved: String) -> CGRect? {
        let values = saved.split(whereSeparator: \.isWhitespace).prefix(4).compactMap { Double($0) }
        guard values.count == 4, values.allSatisfy(\.isFinite), values[2] > 0, values[3] > 0 else { return nil }
        return CGRect(x: values[0], y: values[1], width: values[2], height: values[3])
    }

    /// Keep the user's position, including negative coordinates and positions spanning displays.
    /// Recover only when the title's drag area is no longer reachable after a display change.
    public static func recover(_ frame: CGRect, on screens: [CGRect]) -> CGRect {
        guard !screens.isEmpty else { return frame }
        let dragArea = CGRect(x: frame.minX + 16, y: frame.maxY - 52, width: 150, height: 32)
        if screens.contains(where: {
            let visible = $0.intersection(dragArea)
            return !visible.isNull && visible.width >= 80 && visible.height >= 20
        }) { return frame }

        let nearest = screens.min {
            distance(from: frame, to: $0) < distance(from: frame, to: $1)
        }!
        return CGRect(x: min(max(frame.minX, nearest.minX), max(nearest.minX, nearest.maxX - frame.width)),
                      y: min(max(frame.minY, nearest.minY), max(nearest.minY, nearest.maxY - frame.height)),
                      width: frame.width, height: frame.height)
    }

    private static func distance(from frame: CGRect, to screen: CGRect) -> CGFloat {
        let dx = frame.midX - screen.midX
        let dy = frame.midY - screen.midY
        return dx * dx + dy * dy
    }
}
