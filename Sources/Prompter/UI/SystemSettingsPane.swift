import AppKit

/// Deep links into System Settings → Privacy & Security. macOS 26 ignores the
/// subpage anchor on the legacy `com.apple.preference.security` pane id and
/// strands the user on whichever privacy subpage was open last; the modern
/// `PrivacySecurity.extension` id honors anchors (verified on-device via the
/// System Settings window title). Every settings deep link goes through here.
enum SystemSettingsPrivacyPane: String {
    case microphone = "Privacy_Microphone"
    case accessibility = "Privacy_Accessibility"

    func open() {
        let link = "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?\(rawValue)"
        if let url = URL(string: link) {
            NSWorkspace.shared.open(url)
        }
    }
}
