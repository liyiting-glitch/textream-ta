import Foundation
import Combine

/// Owns the reader bookmark and restores its page, fractional progress and pause state.
@MainActor
protocol TALecturePrompter: AnyObject {
    func startLecture() -> Bool
    func pauseLecture() -> Bool
    func showLectureAnswer(_ text: String)
    func resumeLecture() -> Bool
    func finishLecture()
}

/// Coordinates a lecture without allowing follow-up questions to replace its bookmark.
@MainActor
final class TALectureSession: ObservableObject {
    enum Phase: Equatable {
        case inactive
        case reading
        case question
        case answer
    }

    @Published private(set) var phase: Phase = .inactive

    var isActive: Bool { phase != .inactive }
    var canResume: Bool { phase == .question || phase == .answer }

    // Retained so an adapter created for this session survives for the whole lecture.
    private var prompter: TALecturePrompter?

    /// Replacing an adapter ends its active lecture before releasing its bookmark.
    func attach(_ prompter: TALecturePrompter?) {
        if let current = self.prompter, let prompter, current === prompter { return }
        finish()
        self.prompter = prompter
    }

    @discardableResult
    func start() -> Bool {
        guard !isActive, let prompter, prompter.startLecture() else { return false }
        phase = .reading
        return true
    }

    /// The first interruption captures the bookmark; later questions reuse it.
    func questionStarted() {
        switch phase {
        case .inactive, .question:
            return
        case .reading:
            guard let prompter, prompter.pauseLecture() else { return }
            phase = .question
        case .answer:
            phase = .question
        }
    }

    @discardableResult
    func showAnswer(_ text: String) -> Bool {
        guard isActive, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let prompter else { return false }
        if phase == .reading { questionStarted() }
        guard canResume else { return false }
        prompter.showLectureAnswer(text)
        phase = .answer
        return true
    }

    @discardableResult
    func resume() -> Bool {
        guard canResume, let prompter, prompter.resumeLecture() else { return false }
        phase = .reading
        return true
    }

    func finish() {
        guard isActive else { return }
        // Set this first because closing the reader can synchronously notify us again.
        phase = .inactive
        prompter?.finishLecture()
    }

    /// A reader that has already finished must not be told to finish recursively.
    func readerDidFinish() {
        phase = .inactive
    }

    /// Closing the answer leaves the lecture paused until an explicit resume.
    func answerDidClose() {
        if phase == .answer { phase = .question }
    }
}
