import UsageCore

@MainActor
protocol AppAccessDriving: AnyObject {
    var actualAccess: AppAccess { get }
    func installMenuBar()
    func setDockVisible(_ visible: Bool)
    func removeMenuBar()
}

struct AccessTransitionResult {
    let actual: AppAccess
    let error: String?
}

@MainActor
enum AccessTransition {
    static func apply(_ requested: AppAccess, using driver: any AppAccessDriving) -> AccessTransitionResult {
        // Establish and verify every requested replacement before removing anything.
        if requested.menuBar && !driver.actualAccess.menuBar { driver.installMenuBar() }
        if requested.dock && !driver.actualAccess.dock { driver.setDockVisible(true) }
        let prepared = driver.actualAccess
        if (!requested.menuBar || prepared.menuBar) && (!requested.dock || prepared.dock) {
            if !requested.dock && prepared.menuBar && prepared.dock { driver.setDockVisible(false) }
            if !requested.menuBar && driver.actualAccess.menuBar && driver.actualAccess.dock { driver.removeMenuBar() }
        }
        // Native state can also disappear externally. Try recovery without deleting
        // an existing entry. A fully unavailable OS falls back to the visible window.
        if !driver.actualAccess.valid { driver.setDockVisible(true) }
        if !driver.actualAccess.valid { driver.installMenuBar() }
        let actual = driver.actualAccess
        let error: String?
        if actual == requested { error = nil }
        else if !actual.valid { error = "App access is unavailable. Keep this window open and retry an access setting." }
        else { error = "macOS could not apply that access mode. Keeping the available menu bar or Dock entry." }
        return AccessTransitionResult(actual: actual, error: error)
    }
}
