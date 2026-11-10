# Changelog

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
