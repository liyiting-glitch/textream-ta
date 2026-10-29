import Foundation

@MainActor
final class FakeCapture: TACapturing {
    var onText: ((String) -> Void)?
    var onError: ((String) -> Void)?
    var starts = 0
    var stops = 0
    var resets = 0
    func start(locale: String) async throws { starts += 1 }
    func stop() { stops += 1 }
    func resetQuestion() { resets += 1 }
}

@MainActor
final class FakeResponses: TAResponding {
    struct Call {
        let question: String
        let context: String
        let history: [TATurn]
        let delta: (String) -> Void
        let finish: CheckedContinuation<Void, Error>
    }
    var calls: [Call] = []
    func stream(key: String, model: String, question: String, context: String,
                language: String, history: [TATurn], onDelta: @escaping (String) -> Void) async throws {
        try await withCheckedThrowingContinuation { continuation in
            calls.append(Call(question: question, context: context, history: history,
                              delta: onDelta, finish: continuation))
        }
    }
}

@MainActor
final class FakeModelLecturePrompter: TALecturePrompter {
    struct Position: Equatable {
        var page: Int
        var progress: Double
        var paused: Bool
    }

    var position = Position(page: 7, progress: 0.41875, paused: false)
    private(set) var bookmark: Position?
    private(set) var starts = 0
    private(set) var pauses = 0
    private(set) var resumes = 0
    private(set) var finishes = 0
    private(set) var answers: [String] = []

    func startLecture() -> Bool {
        starts += 1
        bookmark = nil
        return true
    }

    func pauseLecture() -> Bool {
        pauses += 1
        if bookmark == nil { bookmark = position }
        position.paused = true
        return true
    }

    func showLectureAnswer(_ text: String) {
        answers.append(text)
        position = Position(page: 0, progress: 0, paused: false)
    }

    func resumeLecture() -> Bool {
        guard let bookmark else { return false }
        resumes += 1
        position = bookmark
        self.bookmark = nil
        return true
    }

    func finishLecture() {
        finishes += 1
        bookmark = nil
    }
}

@main
struct TARegressionTests {
    @MainActor static func main() async throws {
        var checks = 0
        func check(_ condition: @autoclosure () -> Bool, _ message: String) {
            guard condition() else { fatalError(message) }
            checks += 1
        }
        func settle() async { try? await Task.sleep(nanoseconds: 30_000_000) }

        var decoder = TASSEDecoder()
        check(decoder.append(": keepalive") == nil, "SSE comment")
        check(decoder.append("event: response.output_text.delta") == nil, "SSE event field")
        check(decoder.append("data: {\"type\":\"response.output_text.delta\",") == nil, "SSE multiline first")
        check(decoder.append("data: \"delta\":\"你好 🌟\"}") == nil, "SSE multiline second")
        let payload = decoder.append("")!
        let event = try TAResponseEvent.decode(payload)
        check(event == .delta("你好 🌟"), "Unicode streaming")
        check(decoder.append("") == nil, "Empty SSE frame")
        let completed = try TAResponseEvent.decode(Data("{\"type\":\"response.completed\"}".utf8))
        check(completed == .completed, "Completion recognition")
        for kind in ["response.failed", "response.incomplete", "error"] {
            let event = try TAResponseEvent.decode(Data("{\"type\":\"\(kind)\"}".utf8))
            if case .failed = event { checks += 1 } else { fatalError("Failure event ignored") }
        }
        do { _ = try TAResponseEvent.decode(Data("bad json".utf8)); fatalError("Malformed event accepted") }
        catch { checks += 1 }

        // Exercise one byte at a time, including split Unicode and every SSE line ending.
        var lineDecoder = TALineDecoder()
        var lines: [String] = []
        for byte in "\u{FEFF}data: 你好 🌟\r\n\r\ndata: second\n\ndata: third\r\r".utf8 {
            if let line = try lineDecoder.append(byte) { lines.append(line) }
        }
        check(lines == ["data: 你好 🌟", "", "data: second", "", "data: third", ""], "Preserve SSE delimiters, Unicode and CRLF")

        let turns = (0..<6).map { TATurn(question: "q\($0)", answer: "a\($0)") }
        let request = try TAResponseClient.request(key: "test-placeholder", model: "test-model",
            question: String(repeating: "q", count: 9000), context: String(repeating: "c", count: 17000),
            language: "English", history: turns)
        let json = try JSONSerialization.jsonObject(with: request.httpBody!) as! [String: Any]
        check(request.url?.absoluteString == "https://api.openai.com/v1/responses", "Credential destination")
        check(request.httpMethod == "POST", "HTTP method")
        check(json["store"] as? Bool == false, "Do not store responses")
        check(json["stream"] as? Bool == true, "Streaming enabled")
        let input = json["input"] as! [[String: String]]
        check(input.count == 8, "Context + bounded history + question")
        check(input[1]["content"] == "q3", "Only last three turns")
        check(input.last?["content"]?.count == 8000, "Question bound")
        check(input[0]["content"]!.hasSuffix(String(repeating: "c", count: 16000)), "Notes bound")
        check(!String(data: request.httpBody!, encoding: .utf8)!.contains("test-placeholder"), "Key excluded from prompt")
        check(json["reasoning"] == nil, "Unknown models keep their supported defaults")
        let terraRequest = try TAResponseClient.request(key: "test-placeholder", model: "gpt-6.1-terra",
            question: "What is overfitting?", context: "", language: "English", history: [])
        let terraJSON = try JSONSerialization.jsonObject(with: terraRequest.httpBody!) as! [String: Any]
        check((terraJSON["reasoning"] as? [String: String])?["effort"] == "low", "Terra live replies use low reasoning effort")

        let capture = FakeCapture()
        let client = FakeResponses()
        let model = TAAssistantModel(capture: capture, client: client,
            loadKey: { "test-placeholder" }, writeKey: { _ in })
        var shownReplies: [String] = []
        model.autoShowReplies = true
        model.onReplyReady = { shownReplies.append($0) }
        check(!model.enabled && capture.starts == 0 && client.calls.isEmpty, "Off by default")
        model.question = "Should never send"
        model.generate()
        check(client.calls.isEmpty, "Disabled generation")
        model.setEnabled(true)
        await settle()
        check(model.listening, "Capture starts only when enabled")
        model.editQuestion("First question")
        check(!model.listening, "Editing pauses capture")
        model.generate()
        await settle()
        check(client.calls.count == 1, "Manual request")
        client.calls[0].delta("First answer")
        check(model.answer == "First answer", "Stream reaches UI")
        model.newStudent()
        client.calls[0].delta("late stale text")
        client.calls[0].finish.resume()
        await settle()
        check(model.answer.isEmpty && model.question.isEmpty, "New student cancels stale output")
        check(shownReplies.isEmpty, "Cancelled partial text never opens the prompter")
        for index in 1...5 {
            model.editQuestion("Question \(index)")
            model.generate()
            await settle()
            client.calls[index].delta("Answer \(index)")
            client.calls[index].finish.resume()
            await settle()
        }
        check(client.calls[1].history.isEmpty, "New student clears history")
        check(client.calls[5].history.count == 3, "History bounded to three turns")
        check(shownReplies == (1...5).map { "Answer \($0)" }, "Completed replies each reach prompter once")
        model.editQuestion("Cancelled question")
        model.generate()
        await settle()
        model.setEnabled(false)
        client.calls[6].delta("must not display")
        client.calls[6].finish.resume()
        await settle()
        check(model.answer.isEmpty && !model.generating && !model.listening, "Disable invalidates active response")
        check(shownReplies.count == 5, "Disabled stale response never opens prompter")

        model.pauseSeconds = 1
        model.setEnabled(true)
        await settle()
        capture.onText?("What is a policy")
        try await Task.sleep(nanoseconds: 650_000_000)
        capture.onText?("What is a policy gradient?")
        try await Task.sleep(nanoseconds: 500_000_000)
        check(client.calls.count == 7, "Wait for a full pause after revisions")
        try await Task.sleep(nanoseconds: 650_000_000)
        check(client.calls.count == 8 && client.calls[7].question == "What is a policy gradient?", "Automatic pause trigger")
        client.calls[7].delta("A policy gradient is…")
        client.calls[7].finish.resume()
        await settle()
        check(shownReplies.last == "A policy gradient is…" && model.listening, "Automatic prompter preserves capture for next student question")
        capture.onText?("Another question")
        model.setEnabled(false)
        try await Task.sleep(nanoseconds: 1_100_000_000)
        check(client.calls.count == 8, "Disable cancels pending debounce")
        model.setEnabled(true)
        await settle()
        try await Task.sleep(nanoseconds: 1_100_000_000)
        check(client.calls.count == 8, "Resume does not send stale transcript")
        model.editQuestion("Failed request")
        model.generate()
        await settle()
        client.calls[8].delta("Partial response")
        client.calls[8].finish.resume(throwing: TAError.message("Interrupted test stream"))
        await settle()
        check(shownReplies.count == 6 && model.error != nil, "Failed partial answer never opens the prompter")
        model.autoShowReplies = false
        model.editQuestion("Manual display only")
        model.generate()
        await settle()
        client.calls[9].delta("Manual answer")
        client.calls[9].finish.resume()
        await settle()
        check(shownReplies.count == 6 && model.answer == "Manual answer", "Auto display can be disabled without losing answer")
        model.setEnabled(false)

        let missingKey = TAAssistantModel(capture: FakeCapture(), client: FakeResponses(), loadKey: { "" }, writeKey: { _ in })
        missingKey.setEnabled(true)
        check(!missingKey.enabled && missingKey.error != nil, "Key required before capture")
        let originalChecks = checks

        let lectureCapture = FakeCapture()
        let lectureClient = FakeResponses()
        let lectureReader = FakeModelLecturePrompter()
        let lectureModel = TAAssistantModel(capture: lectureCapture, client: lectureClient,
            loadKey: { "test-placeholder" }, writeKey: { _ in })
        lectureModel.lecture.attach(lectureReader)
        lectureModel.automatic = false
        lectureModel.autoShowReplies = true
        let lectureExcerpt = String(repeating: "L", count: 12000) + "EXCERPT-OUTSIDE-LIMIT"
        let lectureNotes = "COURSE-NOTES-START " + String(repeating: "N", count: 8000) + " NOTES-END"
        lectureModel.lectureReference = { lectureExcerpt }
        lectureModel.courseContext = lectureNotes
        var discussionReplies: [String] = []
        lectureModel.onReplyReady = { discussionReplies.append($0) }

        @MainActor func requestLectureReply() async -> FakeResponses.Call {
            let previousCount = lectureClient.calls.count
            lectureModel.generate()
            await settle()
            check(lectureClient.calls.count == previousCount + 1, "Lecture question starts exactly one mock request")
            return lectureClient.calls[previousCount]
        }

        lectureModel.startLecture()
        check(!lectureModel.lecture.isActive && lectureReader.starts == 0 && lectureModel.error != nil,
              "A disabled assistant cannot start a lecture")
        lectureModel.setEnabled(true)
        await settle()
        lectureModel.startLecture()
        check(lectureModel.lecture.phase == .reading && lectureModel.listening && lectureCapture.starts == 1,
              "Starting a lecture keeps the existing meeting capture active")
        let initialLecturePosition = lectureReader.position
        lectureCapture.onText?("Hi")
        check(lectureModel.lecture.phase == .reading && lectureReader.pauses == 0,
              "A two-character transcript does not interrupt the lecture")
        lectureCapture.onText?("What is a policy")
        lectureCapture.onText?("What is a policy gradient?")
        check(lectureModel.lecture.phase == .question && lectureReader.pauses == 1,
              "The first and revised question transcripts pause the lecture only once")
        check(lectureReader.bookmark == initialLecturePosition && lectureModel.listening,
              "Transcript interruption preserves the exact lecture bookmark without stopping capture")
        let lectureFirst = await requestLectureReply()
        check(lectureFirst.question == "What is a policy gradient?", "Lecture request uses the revised question")
        check(lectureFirst.context.count == 16000 && lectureFirst.context.contains(String(repeating: "L", count: 12000)),
              "Lecture reference retains at most a 12000-character excerpt within 16000 combined characters")
        check(!lectureFirst.context.contains("EXCERPT-OUTSIDE-LIMIT")
              && lectureFirst.context.contains("COURSE-NOTES-START") && !lectureFirst.context.contains("NOTES-END"),
              "Lecture context excludes the reference tail and bounds the added course notes")
        lectureFirst.delta("Lecture answer one")
        lectureFirst.finish.resume()
        await settle()
        check(lectureModel.lecture.phase == .answer && lectureReader.answers == ["Lecture answer one"]
              && discussionReplies.isEmpty,
              "A completed lecture answer uses the lecture reader instead of free discussion")
        check(lectureModel.listening && lectureCapture.stops == 0 && lectureReader.resumes == 0,
              "A successful answer keeps meeting capture running and waits for manual lecture resume")
        lectureCapture.onText?("Can you give an example?")
        let lectureFollowup = await requestLectureReply()
        lectureFollowup.delta("Follow-up example")
        lectureFollowup.finish.resume()
        await settle()
        check(lectureReader.pauses == 1 && lectureReader.bookmark == initialLecturePosition,
              "Follow-up requests never replace the original lecture bookmark")
        lectureModel.resumeLecture()
        check(lectureModel.lecture.phase == .reading && lectureReader.position == initialLecturePosition
              && lectureReader.resumes == 1 && lectureModel.question.isEmpty && lectureModel.listening,
              "Explicit resume restores the original page and fractional progress while capture continues")

        lectureCapture.onText?("A question with a delayed answer")
        let resumedStaleCall = await requestLectureReply()
        resumedStaleCall.delta("Partial pending answer")
        lectureModel.resumeLecture()
        let textAtResume = lectureModel.answer
        resumedStaleCall.delta(" must be ignored")
        resumedStaleCall.finish.resume()
        await settle()
        check(lectureModel.lecture.phase == .reading && !lectureModel.generating
              && lectureModel.question.isEmpty && lectureModel.answer == textAtResume,
              "Resuming invalidates pending question state and ignores late response deltas")
        check(lectureReader.answers.count == 2 && discussionReplies.isEmpty,
              "A late completion cannot replace the resumed lecture or reopen free discussion")

        lectureCapture.onText?("A question with a failed stream")
        let failedLectureCall = await requestLectureReply()
        failedLectureCall.delta("Incomplete lecture answer")
        failedLectureCall.finish.resume(throwing: TAError.message("Mock lecture stream failed"))
        await settle()
        check(lectureModel.lecture.phase == .question && lectureModel.lecture.canResume
              && lectureModel.error != nil && !lectureModel.generating,
              "A failed response leaves the original lecture paused and resumable")
        check(lectureReader.bookmark == initialLecturePosition && lectureReader.answers.count == 2
              && lectureModel.listening,
              "Failed partial replies do not replace the lecture or stop meeting capture")

        lectureModel.autoShowReplies = false
        lectureCapture.onText?("Display this answer manually")
        let manualLectureCall = await requestLectureReply()
        manualLectureCall.delta("A manually selected answer")
        manualLectureCall.finish.resume()
        await settle()
        check(lectureModel.answer == "A manually selected answer" && lectureReader.answers.count == 2
              && lectureModel.lecture.phase == .question,
              "Disabling automatic display retains the completed answer without replacing the lecture")
        lectureModel.readAnswer()
        check(lectureReader.answers.last == "A manually selected answer" && discussionReplies.isEmpty
              && lectureModel.lecture.phase == .answer,
              "Manual Read in prompter still routes completed answers through the lecture session")
        lectureModel.lecture.answerDidClose()
        check(lectureModel.lecture.phase == .question && lectureModel.lecture.canResume && lectureReader.resumes == 2,
              "Closing the answer never resumes the saved lecture automatically")
        lectureModel.resumeLecture()

        lectureModel.autoShowReplies = true
        lectureCapture.onText?("Finish before this answer arrives")
        let finishedStaleCall = await requestLectureReply()
        lectureModel.finishLecture()
        finishedStaleCall.delta("A late answer after finish")
        finishedStaleCall.finish.resume()
        await settle()
        check(!lectureModel.lecture.isActive && lectureReader.finishes == 1
              && !lectureModel.generating && lectureModel.question.isEmpty && lectureModel.listening,
              "Finishing a lecture cancels its pending work and returns to listening for free discussion")
        check(lectureReader.answers.count == 3 && discussionReplies.isEmpty,
              "A late answer after finish cannot open either reader")
        lectureCapture.onText?("A free discussion question")
        let discussionCall = await requestLectureReply()
        check(discussionCall.context == lectureNotes && !discussionCall.context.contains("EXCERPT-OUTSIDE-LIMIT"),
              "Free discussion excludes the lecture reference and keeps its course context")
        discussionCall.delta("A free discussion answer")
        discussionCall.finish.resume()
        await settle()
        check(discussionReplies == ["A free discussion answer"] && lectureReader.answers.count == 3,
              "Free discussion resumes its original completed-answer callback")

        lectureModel.startLecture()
        lectureCapture.onText?("Close the lecture before this answer")
        let readerClosedCall = await requestLectureReply()
        lectureModel.lecture.readerDidFinish()
        readerClosedCall.delta("A late answer after the reader closes")
        readerClosedCall.finish.resume()
        await settle()
        check(!lectureModel.lecture.isActive && !lectureModel.generating && lectureModel.question.isEmpty
              && lectureReader.finishes == 1,
              "Natural reader completion clears pending work without recursively closing the adapter")
        check(discussionReplies.count == 1 && lectureReader.answers.count == 3,
              "A reader-close completion cannot fall back to opening an unrelated answer overlay")

        lectureModel.startLecture()
        lectureModel.automaticLectureInterruption = false
        let pausesBeforeOptOut = lectureReader.pauses
        lectureCapture.onText?("A transcript while automatic interruption is off")
        check(lectureModel.lecture.phase == .reading && lectureReader.pauses == pausesBeforeOptOut,
              "Opting out of automatic interruption keeps the lecture reading when audio is transcribed")
        lectureModel.pauseLectureForQuestion()
        check(lectureModel.lecture.phase == .question && lectureReader.pauses == pausesBeforeOptOut + 1,
              "The explicit pause-for-question action still works with automatic interruption off")
        lectureModel.resumeLecture()
        lectureCapture.onText?("Generate this opt-out question manually")
        let optOutCall = await requestLectureReply()
        check(lectureModel.lecture.phase == .question && lectureReader.pauses == pausesBeforeOptOut + 2,
              "Manual generation pauses the lecture even when transcript interruption is off")
        lectureModel.resumeLecture()
        optOutCall.finish.resume()
        await settle()
        lectureModel.editQuestion("A manually typed question")
        check(lectureModel.lecture.phase == .question && !lectureModel.listening,
              "Editing a question pauses both the lecture and audio even with automatic interruption off")
        lectureModel.resumeLecture()
        await settle()
        check(lectureModel.lecture.phase == .reading && !lectureModel.listening && lectureModel.question.isEmpty,
              "Resuming after a typed question clears stale text while keeping meeting capture paused")
        lectureModel.setEnabled(false)
        check(!lectureModel.lecture.isActive && !lectureModel.listening,
              "Disabling the assistant also finishes its lecture session")

        let optOutCapture = FakeCapture()
        let optOutClient = FakeResponses()
        let optOutReader = FakeModelLecturePrompter()
        let optOutModel = TAAssistantModel(capture: optOutCapture, client: optOutClient,
            loadKey: { "test-placeholder" }, writeKey: { _ in })
        optOutModel.lecture.attach(optOutReader)
        optOutModel.automatic = true
        optOutModel.autoShowReplies = true
        optOutModel.pauseSeconds = 1
        optOutModel.automaticLectureInterruption = false
        optOutModel.setEnabled(true)
        await settle()
        optOutModel.startLecture()
        let optOutQuestion = "A student question while automatic interruption is off"
        optOutCapture.onText?(optOutQuestion)
        try await Task.sleep(nanoseconds: 1_150_000_000)
        check(optOutClient.calls.isEmpty && optOutReader.pauses == 0 && optOutModel.lecture.phase == .reading,
              "Automatic replies cannot bypass lecture interruption opt-out after the debounce interval")
        optOutModel.pauseLectureForQuestion()
        check(optOutReader.pauses == 1 && optOutModel.lecture.phase == .question,
              "Manual pause retains an already-transcribed question for automatic answering")
        try await Task.sleep(nanoseconds: 1_150_000_000)
        check(optOutClient.calls.count == 1 && optOutClient.calls[0].question == optOutQuestion,
              "Manually pausing schedules exactly one automatic answer for the pending transcript")
        optOutModel.resumeLecture()
        optOutClient.calls[0].delta("Late automatically generated answer")
        optOutClient.calls[0].finish.resume()
        await settle()
        check(optOutModel.lecture.phase == .reading && !optOutModel.generating
              && optOutModel.question.isEmpty && optOutReader.answers.isEmpty,
              "Resuming also invalidates a response started by the manual-pause debounce")
        optOutModel.setEnabled(false)

        let pausedAudioCapture = FakeCapture()
        let pausedAudioModel = TAAssistantModel(capture: pausedAudioCapture, client: FakeResponses(),
            loadKey: { "test-placeholder" }, writeKey: { _ in })
        pausedAudioModel.lecture.attach(FakeModelLecturePrompter())
        pausedAudioModel.automatic = false
        pausedAudioModel.setEnabled(true)
        await settle()
        pausedAudioModel.startLecture()
        pausedAudioModel.pauseLectureForQuestion()
        pausedAudioModel.pauseAudio()
        let startsBeforePausedResume = pausedAudioCapture.starts
        pausedAudioModel.resumeLecture()
        await settle()
        check(pausedAudioModel.lecture.phase == .reading && !pausedAudioModel.listening
              && !pausedAudioModel.starting && pausedAudioCapture.starts == startsBeforePausedResume,
              "Resuming a lecture respects explicit Pause audio without starting capture again")
        pausedAudioModel.pauseLectureForQuestion()
        pausedAudioModel.finishLecture()
        await settle()
        check(!pausedAudioModel.lecture.isActive && !pausedAudioModel.listening
              && !pausedAudioModel.starting && pausedAudioCapture.starts == startsBeforePausedResume,
              "Finishing a lecture also respects explicit Pause audio without restarting capture")
        pausedAudioModel.setEnabled(false)

        print("PASS: \(checks) TA regression checks (\(originalChecks) original + \(checks - originalChecks) lecture integration; mock services; no network, audio or Keychain access).")
    }
}
