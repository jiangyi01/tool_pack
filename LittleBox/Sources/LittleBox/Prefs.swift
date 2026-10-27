import Foundation

/// Picks the Chinese or English string based on the user's preferred language.
func t(_ zh: String, _ en: String) -> String { Prefs.chinese ? zh : en }

enum Prefs {
    static let chinese = Locale.preferredLanguages.first?.hasPrefix("zh") ?? false
    private static var d: UserDefaults { .standard }

    /// Hovering 📦 opens the box, and hovering an icon in the box opens its menu.
    static var hoverOpen: Bool {
        get { d.object(forKey: "hoverOpen") as? Bool ?? true }
        set { d.set(newValue, forKey: "hoverOpen") }
    }

    /// Items whose click performs an action instead of showing a menu. Hover never
    /// triggers these (it would fire the action by accident); they still open on click.
    /// (v1 used "actionItems"; it was learned by a buggy detector and is discarded.)
    static var actionItems: Set<String> {
        get { Set(d.stringArray(forKey: "actionItemsV2") ?? []) }
        set { d.set(Array(newValue), forKey: "actionItemsV2") }
    }

    /// One-time cleanup of click-only items learned by older builds: Apple's own items
    /// (never click-only) and keys containing a newline (unstable old OneDrive keys).
    static func migrate() {
        guard !d.bool(forKey: "actionItemsMigratedV3") else { return }
        d.set(true, forKey: "actionItemsMigratedV3")
        let kept = actionItems.filter { !$0.hasPrefix("com.apple.") && !$0.contains(where: \.isNewline) }
        if kept != actionItems { actionItems = kept }
    }
}
