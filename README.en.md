# Sozvony — local meeting recorder and transcription for Mac

[Русский](README.md) · **English**

Record microphone and system audio, transcribe speech with Whisper, generate meeting summaries and ask questions about a conversation — locally on your Mac.

**Beta 0.5.3 · Apple Silicon M1 or newer · macOS 15+.** Intel Macs and Windows are not supported. The application interface is currently in Russian; this page is an English guide, not a claim of an English UI.

[**Download the Mac app →**](https://github.com/zan14314/sozvony/releases/tag/v0.5.3) · [Report an issue](https://github.com/zan14314/sozvony/issues)

## What you can do

- Record a meeting using your microphone, all system audio or one selected application. Switch sources during recording.
- Automatically transcribe after stopping, or import an existing audio/video file.
- Read timestamped transcripts and jump to the corresponding audio; view plain text and summaries.
- Search conversation titles and transcript contents, edit text and keep revision history.
- Chat about a conversation with saved messages and references to relevant transcript fragments.
- Combine recordings, export results and recover interrupted recordings.

Useful for meeting notes, lecture transcription, interviews and finding what was agreed in a long conversation. Whisper handles speech recognition; a separately downloaded Qwen model powers summaries, titles and chat.

## Install

1. Download **Sozvony-0.5.3-macOS-Apple-Silicon.zip** from the release Assets. GitHub's “Source code” ZIP is not the app.
2. Extract it and move **Созвоны.app** to Applications.
3. This beta is not Apple-notarized or Developer ID signed. If macOS blocks it and you trust this build, after attempting to launch use **System Settings → Privacy & Security → Open Anyway** for this specific application. Do not globally disable Gatekeeper.
4. Open the setup screen, choose a recordings folder and download a recommended model. Allow microphone and system audio capture if you need recording; importing existing files does not require capture permissions.
5. Make a short test recording and check its audio and transcript.

Models are suggested by RAM: below 16 GB, Whisper Small; at least 16 GB, Whisper Large v3 Turbo and Qwen 4B. This is a guideline, not a performance benchmark. Other compatible models are available in the setup screen.

## Privacy and limitations

Audio and transcripts are processed locally. Model downloads connect to Hugging Face; weights are not bundled. Downloading releases and opening external links also require internet. After installing the models, inference works offline.

This is a beta. Speech recognition can be inaccurate, especially music and vocals. Loop and sparse-output checks address some failures but cannot guarantee accuracy. Chat retrieves relevant fragments and may miss information elsewhere in a long recording. An independent physical M1/macOS 15 test is still needed.

## Update

Wait for processing to finish, quit with ⌘Q and replace the app in Applications. Models and settings live separately in `~/Library/Application Support/ru.personal.calls`; recordings and results are in your chosen folder. Keep those folders when updating.

## Build and contribute

SwiftUI/AppKit, ScreenCaptureKit/CoreAudio and a local Python service. See [the build instructions](README.md#исходники-и-сборка). Rebuilding currently uses the released app as a runtime template; a complete automated dependency build from scratch is not yet provided. Development builds use ad hoc signing unless configured otherwise.

Issues and pull requests are welcome. Include your Mac model, RAM, macOS/app versions and steps to reproduce. Do not post private audio, transcripts or credentials.

## License status

A license for the application's original code has not yet been selected. Publicly visible source does not by itself grant reuse or redistribution rights. Third-party components keep their own licenses; see [THIRD_PARTY.md](THIRD_PARTY.md). Model licenses are linked in the downloader.
