// Textream TA uses explicit builds so an upstream official download cannot
// accidentally replace this independently identified application.

import AppKit

@MainActor
final class UpdateChecker {
    static let shared = UpdateChecker()

    func showBuildDownloads() {
        let alert = NSAlert()
        alert.messageText = "Textream TA builds"
        alert.informativeText = "This is the custom TA edition. Download a verified TA build from its GitHub Actions page. Official Textream updates do not include the TA features."
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Open TA builds")
        alert.addButton(withTitle: "Cancel")
        if alert.runModal() == .alertFirstButtonReturn,
           let url = URL(string: "https://github.com/liyiting-glitch/textream-ta/actions/workflows/ta-checks.yml") {
            NSWorkspace.shared.open(url)
        }
    }
}
