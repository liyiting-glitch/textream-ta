import Foundation

@MainActor
private final class FakeLecturePrompter: TALecturePrompter {
    struct Bookmark: Equatable {
        var page: Int
        var progress: Double
        var paused: Bool
        var text: String
    }

    var reader = Bookmark(page: 4, progress: 0.3725, paused: false, text: "Original lecture")
    private(set) var bookmark: Bookmark?
    private(set) var answers: [String] = []
    private(set) var starts = 0
    private(set) var pauses = 0
    private(set) var resumes = 0
    private(set) var finishes = 0
    var allowStart = true
    var allowPause = true
    var allowResume = true
    var onFinish: (() -> Void)?

    func startLecture() -> Bool {
        starts += 1
        return allowStart
    }

    func pauseLecture() -> Bool {
        pauses += 1
        guard allowPause else { return false }
        if bookmark == nil { bookmark = reader }
        reader.paused = true
        return true
    }

    func showLectureAnswer(_ text: String) {
        answers.append(text)
        // Simulate an answer reader with unrelated pagination and scroll progress.
        reader = Bookmark(page: 0, progress: 0, paused: false, text: text)
    }

    func resumeLecture() -> Bool {
        resumes += 1
        guard allowResume, let bookmark else { return false }
        reader = bookmark
        self.bookmark = nil
        return true
    }

    func finishLecture() {
        finishes += 1
        bookmark = nil
        onFinish?()
    }
}

@main
struct TALectureRegressionTests {
    @MainActor static func main() {
        var checks = 0
        func check(_ condition: @autoclosure () -> Bool, _ message: String) {
            guard condition() else { fatalError(message) }
            checks += 1
        }

        let session = TALectureSession()
        check(session.phase == .inactive && !session.isActive && !session.canResume,
              "A new session is inactive")
        check(!session.start(), "Starting without a reader fails")
        session.questionStarted()
        check(!session.showAnswer("An answer") && !session.resume(),
              "Inactive sessions ignore questions, answers and resume")

        let reader = FakeLecturePrompter()
        session.attach(reader)
        check(session.start() && session.phase == .reading && session.isActive,
              "Starting enters lecture reading")
        check(!session.start() && reader.starts == 1,
              "Repeated start cannot reset an active lecture")
        check(!session.resume() && reader.resumes == 0,
              "Reading cannot resume a nonexistent interruption")
        let original = reader.reader
        session.questionStarted()
        check(session.phase == .question && session.canResume && reader.pauses == 1,
              "A question pauses the lecture once")
        check(reader.bookmark == original, "The first question stores the original position")
        session.questionStarted()
        check(reader.pauses == 1 && reader.bookmark == original,
              "Partial question updates cannot overwrite the bookmark")
        check(session.showAnswer("Answer one") && session.phase == .answer,
              "A complete answer opens in the reader")
        check(reader.reader.text == "Answer one" && reader.bookmark == original,
              "Answer content does not replace the lecture bookmark")
        reader.reader.progress = 0.83
        session.questionStarted()
        check(session.phase == .question && reader.pauses == 1,
              "A follow-up question stays within the same interruption")
        check(session.showAnswer("Answer two") && reader.bookmark == original,
              "A follow-up answer preserves the original lecture")
        session.answerDidClose()
        check(session.phase == .question && session.canResume && reader.resumes == 0,
              "Closing the answer leaves an explicit resume available")
        check(session.resume() && session.phase == .reading && !session.canResume,
              "Manual resume returns to the lecture")
        check(reader.reader == original && reader.bookmark == nil,
              "Resume restores the exact page, fractional progress and pause state")

        reader.reader = FakeLecturePrompter.Bookmark(page: 8, progress: 0.92175,
                                                    paused: true, text: "Pre-paused lecture")
        let prePaused = reader.reader
        check(session.showAnswer("Direct answer"),
              "A direct answer first captures a lecture interruption")
        check(reader.pauses == 2 && reader.bookmark == prePaused,
              "A later interruption captures the new lecture position")
        check(session.resume() && reader.reader == prePaused && reader.reader.paused,
              "A lecture paused before interruption remains paused after restoration")
        check(!session.showAnswer(" \n\t ") && session.phase == .reading,
              "Empty answers do not pause or replace the lecture")
        check(reader.pauses == 2, "Rejected empty answers do not touch the reader")

        reader.allowPause = false
        session.questionStarted()
        check(session.phase == .reading && !session.canResume && reader.bookmark == nil,
              "A failed pause keeps the lecture reading without a false bookmark")
        check(!session.showAnswer("Cannot show") && reader.answers.count == 3,
              "A pause failure prevents the answer from replacing the lecture")
        reader.allowPause = true
        session.questionStarted()
        reader.allowResume = false
        let failedResumeBookmark = reader.bookmark
        check(!session.resume() && session.phase == .question && session.canResume,
              "A failed question-phase resume remains retryable")
        check(reader.bookmark == failedResumeBookmark,
              "Resume failure preserves the original bookmark")
        check(session.showAnswer("Answer during retry"),
              "An answer can still be displayed after a failed resume")
        check(!session.resume() && session.phase == .answer && session.canResume,
              "A failed answer-phase resume retains the answer state")
        reader.allowResume = true
        check(session.resume() && reader.reader == prePaused,
              "Retrying resume restores the original lecture")

        session.questionStarted()
        reader.onFinish = { session.readerDidFinish() }
        session.finish()
        check(session.phase == .inactive && !session.canResume && reader.finishes == 1,
              "Finishing clears session state even with a reader completion callback")
        check(reader.bookmark == nil, "Finishing clears the adapter bookmark")
        session.finish()
        check(reader.finishes == 1, "Finishing is idempotent")
        reader.onFinish = nil

        reader.allowStart = false
        check(!session.start() && session.phase == .inactive,
              "A failed start leaves the session inactive")
        reader.allowStart = true
        check(session.start(), "A failed start can be retried")
        session.readerDidFinish()
        check(!session.isActive && !session.canResume && reader.finishes == 1,
              "Natural reader completion does not recursively finish the reader")
        session.answerDidClose()
        check(session.phase == .inactive, "Late answer-close notifications cannot reactivate a session")

        check(session.start(), "A finished lecture can start a new session")
        session.attach(reader)
        check(session.phase == .reading && reader.finishes == 1,
              "Attaching the same adapter preserves an active lecture")
        session.questionStarted()
        let replacement = FakeLecturePrompter()
        session.attach(replacement)
        check(!session.isActive && reader.finishes == 2 && reader.bookmark == nil,
              "Replacing an active adapter finishes and releases its old lecture")
        check(session.start() && replacement.starts == 1,
              "The replacement adapter serves the next lecture")
        session.attach(nil)
        check(!session.isActive && replacement.finishes == 1 && !session.start(),
              "Detaching cleans up the active reader and prevents starting")

        print("PASS: \(checks) lecture session regression checks (mock reader; no network, audio or Keychain access).")
    }
}
