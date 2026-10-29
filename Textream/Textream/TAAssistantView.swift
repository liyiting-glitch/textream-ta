import SwiftUI
import AppKit

@MainActor
final class TAAssistantWindow: NSObject, NSWindowDelegate {
    static let shared = TAAssistantWindow()
    private var panel: NSPanel?
    private let model = TAAssistantModel()

    var lectureSession: TALectureSession { model.lecture }

    func resumeLecture() { model.resumeLecture() }

    func show(lecturePrompter: TALecturePrompter? = nil,
              lectureReference: (() -> String)? = nil,
              onRead: @escaping (String) -> Void) {
        if let lecturePrompter { model.lecture.attach(lecturePrompter) }
        model.lectureReference = lectureReference
        model.onReplyReady = onRead
        if let panel { panel.makeKeyAndOrderFront(nil); return }
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 560, height: 730),
                            styleMask: [.titled, .closable, .resizable, .utilityWindow],
                            backing: .buffered, defer: false)
        panel.title = "Textream TA · Assistant"
        panel.level = .floating
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.minSize = NSSize(width: 500, height: 560)
        panel.delegate = self
        panel.contentView = NSHostingView(rootView: TAAssistantView(model: model, onRead: onRead))
        panel.center()
        self.panel = panel
        panel.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func windowWillClose(_ notification: Notification) {
        model.setEnabled(false)
        model.newStudent()
        panel = nil
    }
}

@MainActor
struct TAAssistantView: View {
    @ObservedObject var model: TAAssistantModel
    let onRead: (String) -> Void
    @State private var key = ""
    @State private var setupExpanded = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Group {
                    HStack(alignment: .top) {
                        VStack(alignment: .leading, spacing: 4) {
                            Label("Office hours", systemImage: "bubble.left.and.bubble.right.fill")
                                .font(.title2.weight(.semibold))
                            Text(status).font(.caption).foregroundColor(.secondary)
                        }
                        Spacer()
                        Toggle("Enable TA assistant", isOn: Binding(get: { model.enabled }, set: { model.setEnabled($0) }))
                            .toggleStyle(.switch)
                    }

                    Text("When enabled, meeting audio is transcribed and questions, course notes and the last three turns are sent to OpenAI. Speech recognition may use Apple’s service. API usage is billed separately.")
                        .font(.caption).foregroundColor(.secondary)

                    HStack {
                        Toggle("Auto reply after a pause", isOn: $model.automatic)
                        Spacer()
                        if model.starting { ProgressView().controlSize(.small) }
                        Button(model.listening || model.starting ? "Pause audio" : "Resume audio") {
                            if model.listening || model.starting { model.pauseAudio() }
                            else { model.resumeAudio() }
                        }
                        .disabled(!model.enabled)
                    }
                    HStack {
                        Text("Pause").font(.caption)
                        Slider(value: $model.pauseSeconds, in: 1...5, step: 0.2)
                        Text(String(format: "%.1f s", model.pauseSeconds)).monospacedDigit().font(.caption)
                    }
                    Text("Listens to all Mac playback, including calls in headphones. Your microphone is not captured. Close unrelated audio. A pause is a timing cue, not guaranteed question detection.")
                        .font(.caption).foregroundColor(.secondary)
                    Toggle("Show completed replies in notch automatically", isOn: $model.autoShowReplies)
                }

                TALectureControls(model: model, lecture: model.lecture)

                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("QUESTION / LIVE TRANSCRIPT").font(.caption.weight(.semibold))
                        Spacer()
                        Text("Editing pauses audio").font(.caption2).foregroundColor(.secondary)
                    }
                    TextEditor(text: Binding(get: { model.question }, set: { model.editQuestion($0) }))
                        .font(.body).frame(height: 90)
                        .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.25)))
                    HStack {
                        Button("New student") { model.newStudent() }
                        Spacer()
                        if model.generating {
                            Button("Cancel reply") { model.cancelResponse() }
                        }
                        Button("Generate reply") { model.generate() }
                            .buttonStyle(.borderedProminent)
                            .disabled(!model.enabled || model.question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }

                Divider()
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Text("SUGGESTED REPLY").font(.caption.weight(.semibold))
                        if model.generating { ProgressView().controlSize(.small) }
                        Spacer()
                        Button("Copy") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(model.answer, forType: .string)
                        }.disabled(model.answer.isEmpty)
                        Button("Read in prompter") {
                            model.readAnswer()
                        }.disabled(model.answer.isEmpty || model.generating)
                    }
                    if !model.answeredQuestion.isEmpty {
                        Text(model.answeredQuestion).font(.caption).foregroundColor(.secondary).lineLimit(3)
                    }
                    Text(model.answer.isEmpty ? "Your suggested reply will appear here as it is generated." : model.answer)
                        .font(.system(size: 18)).lineSpacing(5)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, minHeight: 110, alignment: .topLeading)
                    Text("Draft for you to review and say aloud. Nothing is posted to the meeting chat.")
                        .font(.caption2).foregroundColor(.secondary)
                }

                if let error = model.error {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .font(.callout).foregroundColor(.red).textSelection(.enabled)
                }
                if let notice = model.notice { Text(notice).font(.caption).foregroundColor(.secondary) }

                DisclosureGroup("Setup · OpenAI and course context", isExpanded: $setupExpanded) {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack {
                            SecureField(model.hasKey ? "Replace saved API key" : "OpenAI API key", text: $key)
                            Button("Save key") { model.saveKey(key); key = "" }
                                .disabled(key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                            if model.hasKey { Button("Remove") { model.saveKey("") } }
                        }
                        TextField("Model ID", text: $model.model)
                        Text("Default: gpt-6.1-terra (GPT-6.1 Terra). You can enter another Responses-compatible model your API account can access.")
                            .font(.caption).foregroundColor(.secondary)
                        Picker("Speech language", selection: $model.locale) {
                            Text("English (US)").tag("en-US")
                            Text("中文（普通话）").tag("zh-CN")
                        }.disabled(model.listening || model.starting)
                        Picker("Reply language", selection: $model.language) {
                            Text("English").tag("English")
                            Text("中文").tag("Simplified Chinese")
                            Text("Same as question").tag("the language of the student's question")
                        }
                        Text("Course notes / definitions / examples").font(.caption)
                        TextEditor(text: $model.courseContext).frame(height: 100)
                            .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.25)))
                        Text("Only the first 16,000 characters are sent. Notes and conversation stay in memory; closing the panel clears the conversation. This window may appear in screen sharing—share your course window instead.")
                            .font(.caption).foregroundColor(.secondary)
                    }.padding(.top, 10)
                }
            }.padding(20)
        }
        .frame(minWidth: 500, minHeight: 520)
        .onAppear {
            setupExpanded = !model.hasKey
            model.onReplyReady = onRead
        }
        .onDisappear { model.onReplyReady = nil }
    }

    private var status: String {
        if !model.enabled { return "Off · no audio capture or API requests" }
        if model.starting { return "Starting meeting audio…" }
        if model.generating { return "Writing a reply…" }
        if model.listening { return "Listening to meeting audio" }
        return "Audio paused · type a question or resume audio"
    }
}

@MainActor
private struct TALectureControls: View {
    @ObservedObject var model: TAAssistantModel
    @ObservedObject var lecture: TALectureSession

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 10) {
                Label("Lecture + Q&A", systemImage: "text.book.closed")
                    .font(.headline)
                Text(phaseDescription).font(.caption).foregroundColor(.secondary)
                if lecture.isActive {
                    Toggle("Pause lecture when meeting speech is detected", isOn: $model.automaticLectureInterruption)
                        .font(.caption)
                    HStack {
                        if lecture.canResume {
                            Button("Resume lecture") { model.resumeLecture() }
                                .buttonStyle(.borderedProminent)
                        } else {
                            Button("Pause for question") { model.pauseLectureForQuestion() }
                        }
                        Spacer()
                        Button("Finish lecture / free discussion") { model.finishLecture() }
                    }
                    Text("Your script and reading position stay saved. Closing an answer does not resume the lecture; choose Resume lecture when you have finished speaking.")
                        .font(.caption2).foregroundColor(.secondary)
                } else {
                    Button("Start lecture from editor") { model.startLecture() }
                        .disabled(!model.enabled)
                    Text("Put your prepared script in the main editor first. A nearby script excerpt and course notes (16,000 characters combined) are included with lecture questions. The script itself is not rewritten.")
                        .font(.caption2).foregroundColor(.secondary)
                }
                Text("Only Mac playback is heard. Incoming speech can include unrelated audio; use Pause for question if you need to stop before transcription appears.")
                    .font(.caption2).foregroundColor(.secondary)
            }.frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var phaseDescription: String {
        switch lecture.phase {
        case .inactive: return "Free discussion · no lecture position saved"
        case .reading: return "Reading your prepared lecture"
        case .question: return "Lecture paused · answer the question, then resume manually"
        case .answer: return "Temporary answer · your lecture remains paused"
        }
    }
}
