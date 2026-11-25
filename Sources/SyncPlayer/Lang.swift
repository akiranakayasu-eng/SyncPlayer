import AppKit

/// The language of the control window and the messages: English or Japanese (Akira 2026-11-25).
/// Saved per Mac; with nothing saved it follows the Mac's first preferred language.
enum UILang: String, CaseIterable, Identifiable {
    case en, ja
    var id: String { rawValue }
    var label: String { self == .en ? "English" : "日本語" }

    /// Read by L() on every draw; set by AppModel.uiLang before the window redraws.
    static var current: UILang = saved()

    static func saved() -> UILang {
        if let s = UserDefaults.standard.string(forKey: "ui.lang"), let l = UILang(rawValue: s) { return l }
        return (Locale.preferredLanguages.first ?? "en").hasPrefix("ja") ? .ja : .en
    }
}

/// The text in the chosen language: L("日本語", "English").
func L(_ ja: String, _ en: String) -> String {
    UILang.current == .ja ? ja : en
}

/// The control window's own greys (Akira 2026-11-25: the dark mode was too dark and flat). In dark,
/// a slightly lighter base with panels (lists, status) a step darker, like Adobe's panels.
enum UIColors {
    private static func dynamic(dark: NSColor, light: NSColor) -> NSColor {
        NSColor(name: nil) { ap in ap.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light }
    }
    static let base = dynamic(dark: NSColor(srgbRed: 0.200, green: 0.204, blue: 0.220, alpha: 1),
                              light: .windowBackgroundColor)
    /// Numbers that can be clicked and typed (After Effects blue).
    static let editable = dynamic(dark: NSColor(srgbRed: 0.33, green: 0.62, blue: 1.0, alpha: 1),
                                  light: NSColor(srgbRed: 0.08, green: 0.40, blue: 0.85, alpha: 1))
    /// The master's amber: the switch and, in dark, the word. In light the word is a darker amber
    /// so it reads on the light window (about 4.9 on its grey, checks 40 and 41).
    static let masterText = dynamic(dark: NSColor(srgbRed: 0.96, green: 0.70, blue: 0.0, alpha: 1),
                                    light: NSColor(srgbRed: 0.55, green: 0.36, blue: 0.0, alpha: 1))
    static let panel = dynamic(dark: NSColor(srgbRed: 0.150, green: 0.153, blue: 0.168, alpha: 1),
                               light: .controlBackgroundColor)
}
