import Foundation

public struct AppAccess: Equatable, Sendable {
    public var menuBar: Bool
    public var dock: Bool
    public static let defaults = AppAccess(menuBar: true, dock: false)

    public init(menuBar: Bool, dock: Bool) {
        self.menuBar = menuBar
        self.dock = dock
    }

    public var valid: Bool { menuBar || dock }
    public var recovered: AppAccess { valid ? self : .defaults }

    public static func load(from defaults: UserDefaults) -> AppAccess {
        AppAccess(menuBar: defaults.object(forKey: "showInMenuBar") as? Bool ?? true,
                  dock: defaults.object(forKey: "showInDock") as? Bool ?? false).recovered
    }

    public func save(to defaults: UserDefaults) {
        let safe = recovered
        defaults.set(safe.menuBar, forKey: "showInMenuBar")
        defaults.set(safe.dock, forKey: "showInDock")
    }
}

public enum UsagePresentation: String, Sendable {
    case floating, menuBar
}

/// Presentation intent is separate from entry-point preferences and usage services.
public struct PresentationState: Equatable, Sendable {
    public private(set) var mainVisible = false
    public private(set) var cardVisible = false
    public private(set) var saved: UsagePresentation

    public init(saved: UsagePresentation) { self.saved = saved }

    public mutating func launch(background: Bool) {
        mainVisible = !background || saved == .floating
    }

    public mutating func showCard() { cardVisible = true }
    public mutating func closeCard() { cardVisible = false }
    public mutating func openMain() {
        cardVisible = false
        mainVisible = true
        saved = .floating
    }
    public mutating func hideMain() {
        cardVisible = false
        mainVisible = false
        saved = .menuBar
    }
}
