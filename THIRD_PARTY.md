# Third-party components

The release includes licenses in `Rehear.app/Contents/Resources/ThirdParty` and exact third-party source archives in its accompanying ZIP. Keep those files together when redistributing a release.

- whisper.cpp (MIT), pinned source 0c7be696371069e0baa2515ed7aa08d5a5473aa6: https://github.com/ggml-org/whisper.cpp
- llama-helper from Meetily (MIT), with pinned Cargo dependencies in the supplied source archive: https://github.com/meetily/meetily
- FFmpeg 8.0, GPL build with x264, libvpx and Opus; exact source archives and build recipe supplied with the release: https://ffmpeg.org/legal.html
- Python 3.12 (PSF) and OpenSSL: licenses included in the runtime.
- Model weights are not included; origins, revisions and checksums are pinned in `model_downloads.json`. Model licenses are linked in the download UI.

Copied license notices are in `outputs/Созвоны/source/third-party-licenses/`. The app's original code does not yet have a selected public license; third-party licenses remain unchanged.
