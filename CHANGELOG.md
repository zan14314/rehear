# Changelog

## 0.5.4 — 2026-10-26

- Renamed the application, exports, setup and download package to Rehear.
- Preserved the application identifier and local storage for existing users.


## 0.5.3 — 2026-10-26

- Detect unusually short transcripts over sustained audio and retry only the affected window without VAD or glossary prompting.
- Preserve beam quality during recovery; stop publishing if the second result is still suspiciously sparse.
- Keep normal recordings on a single recognition pass.

## 0.5.2

- Record system audio from a selected application and switch sources during recording.
- Avoid a false backend timeout after a long native modal dialog.
- Apple Silicon baseline and macOS 15 compatibility checks.
