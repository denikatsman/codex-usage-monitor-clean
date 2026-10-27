import Foundation

/// Logged or requested service tier. It does not establish the served tier or billing.
public enum UsageTier {
    public static func canonical(_ raw: String?) -> String {
        guard let raw else { return "Unknown" }
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return "Unknown" }
        switch value.lowercased() {
        case "fast", "priority": return "priority"
        case "standard", "default": return "default"
        case "unset": return "unset"
        case "ultrafast": return "ultrafast"
        case "unknown": return "Unknown"
        case "mixed": return "Mixed"
        default: return value
        }
    }

    public static func label(_ raw: String) -> String {
        switch canonical(raw) {
        case "priority": return "Fast (priority)"
        case "default": return "Standard (default)"
        case "unset": return "Unset (logged)"
        case "Unknown": return "Unknown (unavailable)"
        case "Mixed": return "Mixed"
        case "ultrafast": return "Ultrafast (logged)"
        default: return canonical(raw) + " (logged)"
        }
    }

    public static func isComparable(_ raw: String) -> Bool {
        ["priority", "default", "ultrafast"].contains(canonical(raw))
    }
}
