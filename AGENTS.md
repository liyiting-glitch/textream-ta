# Textream TA handoff

These instructions apply to this repository.

- Read `CODEX_HANDOFF.md` before changing the app. The original baseline is `codex/zoom-live-notch`; the independent `liyiting-glitch/textream-ta` build uses `codex/lecture-interrupt-resume`. `master` is an older implementation.
- The independent macOS product is `Textream TA.app` with bundle ID `com.liyitingglitch.textream.ta`. Keep official Textream separate; do not restore its bundle ID, URL scheme, or upstream auto-updater. iOS identity is unchanged.
- The product is a Zoom office-hours assistant: system playback → transcription → concise spoken English → the original notch overlay.
- Preserve GPT-6.1 Terra (`gpt-6.1-terra`), low reasoning effort for that model, continuous system-audio capture, automatic completed-answer display, and Control-Option-Command-A unless the user changes the requirement.
- The user's preferred notch width is 750. This is a local setting, not the upstream default. See `handoff/recommended-settings.json`.
- Do not require upgrading the user's Xcode or logging in to an Apple account. Use the existing GitHub Actions workflow for full builds. The old-toolchain harness is not the full app.
- Preserve opt-in capture and Keychain storage. Never commit or package API keys, credentials, local preferences, meeting recordings, or transcripts.
- Keep audio capture active when showing replies; the assistant overlay uses Classic scrolling to avoid a competing microphone recognizer.
- Validate relevant changes with the regression suite and full cloud build. Distinguish mock, build, and live checks; never report a global shortcut or actual meeting as tested solely because compilation passed.
- After replacing an ad-hoc-signed binary, restore only this app's permissions using the procedure in the handoff. Do not weaken macOS security settings.
- Record changes and remaining limitations in `CODEX_HANDOFF.md` or `TA_ASSISTANT.md` before handing off again.
