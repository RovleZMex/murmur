# Changelog

## 0.2.0 — Unreleased

### Added
- **Settings window** (menu → Settings…, ⌘, or open Murmur again while it's running) with three tabs:
  - **General:** recordings folder, which audio to keep (mixed, separate tracks or none), what happens when a transcript is ready (open it, notify, or nothing), editable global shortcuts, open at login.
  - **Recording:** record Mac audio and mic, mic only, or Mac audio only; choose the microphone.
  - **Transcription:** every language Apple's on-device engine supports; custom speaker labels.
- "Transcript ready" notification that opens the transcript when clicked.
- Test suite (`make test`) covering every setting and their combinations.

### Changed
- Language and open-at-login moved from the menu into Settings.
- Menu bar shortcuts shown in the menu follow your custom shortcuts.

## 0.1.0 — 2026-11-10

First public release.

- Menu bar app with idle / recording / paused / processing states and a live timer.
- Records system audio and microphone simultaneously with ScreenCaptureKit.
- On-device transcription with Apple's SpeechAnalyzer (English and Spanish).
- Transcript labels your microphone as **Me** and system audio as **Others**, with timestamps.
- Each session saved to `~/Documents/Murmur/<date time>/` as `transcript.md` + `audio.m4a`.
- Global shortcuts: ⌃⌥⌘R start/stop, ⌃⌥⌘P pause/resume.
- Open at login.
- Crash-safe recording and `--process` / `--transcribe` command-line tools.
