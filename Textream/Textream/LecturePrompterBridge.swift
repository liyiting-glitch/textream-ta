import AppKit

/// The script keeps its original hosting view while an independent reader shows
/// a temporary answer. Resuming never reparses the script or starts it at zero.
@MainActor
final class LecturePrompterBridge: TALecturePrompter {
    static let shared = LecturePrompterBridge()

    private let service = TextreamService.shared
    private let answerController = NotchOverlayController()
    private weak var session: TALectureSession?
    private var onResumeRequested: (() -> Void)?
    private var isActive = false
    private var interruptedPageIndex: Int?
    private var interruptedPageText: String?

    func attach(session: TALectureSession, onResumeRequested: @escaping () -> Void) {
        if let previousSession = self.session, previousSession !== session, isActive {
            finishLecture()
            previousSession.readerDidFinish()
        }
        self.session = session
        self.onResumeRequested = onResumeRequested
    }

    func startLecture() -> Bool {
        guard !isActive, !service.directorIsReading else { return false }
        let pageIndex: Int
        if service.pages.indices.contains(service.currentPageIndex),
           !service.currentPageText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            pageIndex = service.currentPageIndex
        } else if let firstPage = service.pages.firstIndex(where: {
            !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }) {
            pageIndex = firstPage
        } else {
            return false
        }

        answerController.closeImmediately()
        service.overlayController.closeImmediately()
        service.externalDisplayController.dismiss()
        service.browserServer.hideContent()
        service.readPages.removeAll()
        service.currentPageIndex = pageIndex
        prepareNotch()
        service.hideMainWindowImmediately()

        isActive = true
        service.isLecturePresentation = true
        service.onLectureOverlayDismissed = { [weak self] in
            self?.lectureReaderDidFinish()
        }
        service.readCurrentPage()
        if !service.overlayController.isShowing {
            clearLectureState()
            return false
        }
        return true
    }

    func pauseLecture() -> Bool {
        guard isActive, service.overlayController.pauseForInterruption() else { return false }
        if interruptedPageIndex == nil {
            interruptedPageIndex = service.currentPageIndex
            interruptedPageText = service.currentPageText
        }
        return true
    }

    func showLectureAnswer(_ text: String) {
        guard isActive, interruptedPageIndex != nil,
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        prepareNotch()
        service.hideMainWindowImmediately()
        service.overlayController.hideForInterruption()
        answerController.onResumeLecture = { [weak self] in
            self?.onResumeRequested?()
        }
        answerController.show(text: text, hasNextPage: false) { [weak self] in
            self?.session?.answerDidClose()
        }
    }

    func resumeLecture() -> Bool {
        guard isActive, let pageIndex = interruptedPageIndex,
              service.pages.indices.contains(pageIndex),
              service.pages[pageIndex] == interruptedPageText else { return false }

        let previousPageIndex = service.currentPageIndex
        service.currentPageIndex = pageIndex
        prepareNotch()
        service.hideMainWindowImmediately()
        guard service.overlayController.resumeAfterInterruption() else {
            service.currentPageIndex = previousPageIndex
            return false
        }
        answerController.closeImmediately()
        service.updatePageInfo()
        interruptedPageIndex = nil
        interruptedPageText = nil
        return true
    }

    func finishLecture() {
        guard isActive else { return }
        clearLectureState()
        answerController.onResumeLecture = nil
        answerController.closeImmediately()
        service.overlayController.closeImmediately()
        service.externalDisplayController.dismiss()
        service.browserServer.hideContent()
        service.readPages.removeAll()
        service.onOverlayDismissed?()
    }

    /// Only nearby material is included with a lecture question, within the
    /// existing bounded reference-notes channel. The original pages stay intact.
    func lectureReferenceExcerpt() -> String {
        guard isActive else { return "" }
        let page = interruptedPageText ?? service.currentPageText
        let pageIndex = interruptedPageIndex ?? service.currentPageIndex
        let words = splitTextIntoWords(page)
        guard !words.isEmpty else { return "" }
        let position = max(0, min(Int(service.overlayController.playbackState.timerWordProgress), words.count - 1))
        let lower = max(0, position - 200)
        let upper = min(words.count, position + 800)
        let excerpt = words[lower..<upper].joined(separator: " ")
        return String("Current lecture script, page \(pageIndex + 1), near the paused reading position:\n\(excerpt)".prefix(12_000))
    }

    private func prepareNotch() {
        let settings = NotchSettings.shared
        settings.listeningMode = .classic
        settings.overlayMode = .pinned
        if let screen = NSScreen.screens.first(where: { $0.safeAreaInsets.top > 0 }) {
            settings.notchDisplayMode = .fixedDisplay
            settings.pinnedScreenID = screen.displayID
        }
    }

    private func lectureReaderDidFinish() {
        guard isActive else { return }
        let finishedSession = session
        clearLectureState()
        answerController.onResumeLecture = nil
        answerController.closeImmediately()
        finishedSession?.readerDidFinish()
    }

    private func clearLectureState() {
        isActive = false
        interruptedPageIndex = nil
        interruptedPageText = nil
        service.onLectureOverlayDismissed = nil
        service.isLecturePresentation = false
    }
}
