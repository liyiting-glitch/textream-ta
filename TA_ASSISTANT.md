# Textream TA Assistant (macOS)

This fork adds a switchable office-hours assistant using your own OpenAI API key. For the fixed, packaged version and agent handoff, start with [CODEX_HANDOFF.md](CODEX_HANDOFF.md).

## Get this version

```sh
git clone --branch codex/zoom-live-notch https://github.com/George121380/textream.git
cd textream
open Textream/Textream.xcodeproj
```

Select the **Textream** macOS scheme, choose **My Mac**, configure your own signing team if needed, and build with **Command-R**. The upstream macOS application requires macOS 15+ and Xcode 16+; Xcode 26 is recommended for this combined macOS/iOS project. Xcode 14 cannot build the full project. The original Homebrew/App Store downloads do not include this fork's changes.

## Installing the independent Textream TA edition

The current custom branch is `codex/lecture-interrupt-resume` in `liyiting-glitch/textream-ta`. Its macOS product is **Textream TA.app**, bundle ID `com.liyitingglitch.textream.ta`, build 2. Official Textream remains a separate application. The custom scheme is `textream-ta://`; `.textream` documents remain compatible without claiming the default document handler.

Use the existing **TA Assistant checks** workflow on that branch. The artifact **Textream-TA-unsigned** contains `Textream-TA-unsigned.zip` and `Textream-TA-build.json`; the latter records the source commit, CI URL, independent identity, architectures and hashes. Verify that manifest, unpack, ad-hoc sign the complete app locally, and install it at a stable path such as `~/Applications/Textream TA.app`. Do not overwrite `/Applications/Textream.app`.

The new application has separate preferences and macOS permissions. Enable its Screen & System Audio Recording and Speech Recognition permissions, set the notch width to 750, and enable the assistant only when ready. The Keychain service remains `textream.ta.openai`; any access prompt must be completed normally, and keys must never be exported. A new build does not imply that existing permissions have migrated.

**Download TA builds…** opens this fork's build page; automatic official-upstream update checks are disabled. The original publisher's attribution remains in About.

## Local TA integration test without upgrading Xcode

To test the real TA module independently of the full Textream project, run this from the repository root:

```sh
bash tests/build-integration-app.sh /tmp/TextreamTATest.app
open /tmp/TextreamTATest.app
```

This harness was compiled and launched locally with Xcode 14.1 on macOS 15.7.3. Startup, the missing-key guard, question editing, and conversation clearing were checked in the UI. It uses the same real system-audio capture, OpenAI Responses client, Keychain storage, and assistant view as the main app. Automatic replies start off for controlled testing. Enter your own API key in Setup, save it, and enable the assistant when ready. The command above builds a temporary test application; rerun it if the system clears that directory.

The harness is a separate test application. Its **Read in prompter** button opens a simple reader to check answer handoff; it does not validate Textream's original notch overlay. The full app still has the build requirements listed above. A real streamed response from GPT-6.1 Terra was verified locally with a saved API key. After granting Speech Recognition and Screen & System Audio Recording and restarting the app, an English question played in QuickTime was transcribed correctly and automatically received a complete Terra reply after the pause, without pressing Generate reply. Audio capture was paused after the test.

## Use it

1. Open **TA Assistant → Open TA Assistant…**, or press **Control-Option-Command-A** from Zoom or any other app while Textream is running. This global shortcut replaces Command-Shift-A to avoid Zoom’s mute shortcut.
2. Expand **Setup** and save your OpenAI API key. It is saved in this Mac's Keychain, not the repository. Each person cloning this fork enters their own key. API usage is billed separately from a ChatGPT subscription.
3. Pick the speech language and reply language, and optionally paste course definitions, reference notes or examples. The default model is GPT-6.1 Terra (`gpt-6.1-terra`); the model ID is editable. Existing model preferences are preserved, so change the Model ID once if you previously selected another model.
4. Turn on **Enable TA assistant**. Allow Speech Recognition and Screen & System Audio Recording when macOS asks. Depending on macOS, you may need to quit and reopen the app after granting access.
5. Play the meeting audio normally, including through headphones. The question appears in **Question / live transcript**. With **Auto reply after a pause** on, a pause of 1.8 seconds starts a draft; adjust the pause from 1 to 5 seconds.
6. The suggested answer streams into the assistant window. By default, each successfully completed reply also opens automatically in Textream’s original notch overlay. It uses Classic scrolling without a microphone recognizer, so meeting playback transcription continues for the next question. Turn off **Show completed replies in notch automatically** for manual control; **Read in prompter** remains available. Failed or cancelled partial responses do not open the overlay.

For Zoom office hours, set **Speech language → English (US)** and **Reply language → English**, then enable the assistant. Questions are detected from Mac playback, including Zoom through headphones; your local microphone is not captured. The reply is a concise 4–6 sentence speaking draft. The default Terra model now uses `reasoning.effort: low` to reduce waiting; other model IDs retain their API defaults. A completed reply shows its generation time in the assistant.

You can switch off automatic replies and use **Generate reply** when the full question is ready. Typing or correcting a question pauses audio so speech cannot overwrite your edit. **New student** cancels work and clears conversational context. Closing the assistant stops capture and requests and clears the conversation.

## Lecture + Q&A (local source update)

This mode supports a prepared teaching segment followed by free discussion. It is implemented in the local source and has not yet been built into a replacement full application.

1. Put your prepared script in the main Textream editor, using separate pages if useful. Enable the TA assistant, then choose **Start lecture from editor**. The lecture starts on the selected nonempty page (or the first nonempty page) in Classic scrolling and Pinned to Notch mode.
2. When meeting playback produces a transcript, the lecture pauses at its current displayed reading position. You can use **Pause for question** to pause earlier. Automatic interruption depends on transcription timing and also reacts to unrelated playback; switch off **Pause lecture when meeting speech is detected** for manual interruption control.
3. A completed answer appears in a separate temporary reader. The original script, page and fractional reading position stay intact. Follow-up questions reuse the original saved position. Audio capture continues while the answer is shown.
4. When you have finished answering, choose **Resume lecture** in the answer reader or the assistant panel. This explicitly restores the original reader and its previous pause state. Closing an answer or reaching its end does not resume the lecture automatically. Resuming cancels pending responses so an old answer cannot overwrite the restored script. Your explicit Pause audio setting is preserved; use Resume audio separately when you want to listen again.
5. Choose **Finish lecture / free discussion** for the second segment. Lecture readers close; the enabled assistant continues handling questions in the existing discussion mode. Disabling or closing the assistant ends the lecture. If the saved script page was edited or removed during the interruption, recovery is refused rather than jumping to different text.

During a lecture, up to 12,000 characters near the reading position are included as reference content with a question. The combined lecture excerpt and course notes remain capped at 16,000 characters. Replies never rewrite the editor pages. Lecture reading uses the original notch; external/browser mirror output is hidden during this mode so a second copy cannot keep advancing.

Local validation includes **90 TA mock checks** and **40 standalone lecture-session mock checks**. The full Swift sources can be typechecked with this workspace's isolated CLT overlay while omitting the Xcode-only `#Preview` declaration. These checks are not a full Xcode build and do not establish live window, audio, API, or Zoom behavior. The existing cloud workflow now also runs the lecture-session checks once the user chooses to build. No GitHub login or upload was performed for this update.

## Scope and data

- Captures **all Mac playback**, not just Zoom/Meet, and excludes this application's own output. The microphone is not connected to the assistant. Close unrelated audio. This is not speaker diarization; system playback can still contain a recording of your own voice or shared videos.
- A pause is only a timing heuristic. It cannot reliably distinguish a finished question from a pause within a sentence. Use manual generation or a longer pause when needed.
- Audio goes to Apple's speech recognition; on-device recognition is requested when supported, otherwise Apple may process it. No screen frames are consumed or sent to GPT.
- The recognized question (up to 8,000 characters), course notes (first 16,000 characters), and at most the last three successful Q/A turns are sent to `https://api.openai.com/v1/responses` over HTTPS. No other endpoint or redirect receives the key. The client sends `store: false`; this does not promise zero retention under all provider policies.
- Transcript, replies and notes stay in app memory. Course notes survive closing/reopening the panel within the same app session; conversations do not. Model and language preferences are saved locally.
- Responses are drafts. Nothing is posted to meeting chat or sent to students automatically. The assistant window can appear in screen sharing; share the course window instead of the entire desktop when appropriate.
- Failed calls are not automatically retried. HTTP authentication/quota errors and interrupted or incomplete streams are surfaced in the UI; visible text after an error may be partial.

## Validation

The packaged handoff app source (`8ff2e52`) passed all **44** regression checks and the full universal macOS build in [GitHub Actions](https://github.com/George121380/textream/actions/runs/40820924263). The full application was installed and launched on macOS 15.7.3 without upgrading Xcode; the saved Terra key was recognized and system-audio capture was restored. The notch width limit is 900, with 750 applied locally. Actual Zoom trial questions produced English answers; observed generation times of 1.8–2.0 seconds exclude transcription and pause detection. The revised shortcut opened the assistant locally and registered globally, but physical-keyboard invocation from a foreground Zoom meeting still needs explicit confirmation.

For a locally ad-hoc-signed update, macOS may retain the previous binary’s Screen & System Audio Recording requirement even when the switch is on. Remove only Textream’s stale entry, add the newly installed Textream.app from its exact path, and choose Quit & Reopen. Speech Recognition may also need toggling and a restart. Keep the app at a stable install path; do not disable macOS security protections.

An earlier baseline of the full universal macOS app (Apple Silicon and Intel) and all 36 mock regression checks passed with Xcode 26.3 in [GitHub Actions](https://github.com/George121380/textream/actions/runs/40815599146). The tested application sources, including the Terra default and setup guidance, are from commit `fa77ee4`.

The [TA Assistant checks workflow](https://github.com/George121380/textream/actions/workflows/ta-checks.yml) repeats these checks for relevant pushes and pull requests, and can also be run manually. Each successful run keeps validation logs and a `Textream-TA-unsigned` test artifact for seven days. This artifact is unsigned and not notarized; a successful build does not verify local permissions, audio capture, or a real OpenAI response.

The four new feature files compile together against the installed macOS SDK. The regression checks exercise UTF-8/SSE framing, error events, request destination and storage settings, bounded context, cancellation, stale results, debounce, missing keys, and new-student resets. They use mocks, with no network, audio or Keychain access.

Run from the repository root:

```sh
swiftc -swift-version 5 -target "$(uname -m)-apple-macosx13.0" \
  Textream/Textream/TA*.swift TARegressionTests.swift \
  -o /tmp/textream-ta-tests
/tmp/textream-ta-tests
```

The test executable targets macOS 13 solely to check the standalone feature with older toolchains. It does not change the full app's macOS 15 requirement.

Local live checks passed for manual GPT-6.1 Terra responses and the complete English system-playback → transcription → automatic Terra response flow. The audio test used a synthesized question played in QuickTime: “What is the difference between supervised learning and reinforcement learning?” The transcript retained the complete question and Terra returned a complete comparison.

Further validation should cover sustained Zoom sessions, Chinese transcription, audio device changes, permission revocation, long-session recognizer rotation, multiple displays and full-screen behavior, and the new global shortcut from a physical keyboard. The short local trials do not establish all of those cases.

## Files

- `TAMeetingCapture.swift`: ScreenCaptureKit audio and Apple speech recognition, with recognizer rotation.
- `TAResponseClient.swift`: Keychain storage, bounded Responses requests and cancellable SSE streaming.
- `TAAssistantModel.swift`: lifecycle, pause detection, conversation and cancellation guards.
- `TAAssistantView.swift`: floating assistant window and setup.
- `TextreamApp.swift`: menu entry and existing-overlay integration.
- `TARegressionTests.swift`: executable regression suite outside the app target.
- `tests/TAIntegrationHarness.swift` and `tests/build-integration-app.sh`: build and run the real TA module as a separate local integration test.

The Xcode macOS target uses a synchronized source folder, so the new files are included automatically. The iOS app is unchanged. Upstream licensing and attribution are preserved.
