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
