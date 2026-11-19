# Toolbox Pro Max

Cojo's Toolbox, but Pro. And Max. A native Mac app (SwiftUI) where you wire tools together as a node graph
and everything previews live: photos, video, sound, PDFs, text, and downloads from YouTube & co.

The joke is the packaging: no Electron, no bundled ffmpeg. The work is done by what macOS already has
(Core Image, AVFoundation, Vision, PDFKit), so the whole app is a **2.3 MB disk image** against
Toolbox 0.3.0's 164 MB.

## What's inside (v0.1)

| | Nodes |
| --- | --- |
| **Inputs** | Image, Several Images (files or a folder), Video, Audio, PDF, Text, Download (yt-dlp) |
| **Image** | Resize, Crop, Rotate & Flip, Adjust, Dither, ASCII Art, Lift Subject (background removal) |
| **Video** | Trim Video, Grab Frame. Every Image node also works on video, frame by frame |
| **Audio** | Extract Audio, Trim Audio, Fade, Normalize, Mix to Mono |
| **PDF** | Merge, Pick Pages, Watermark, Page Numbers, Images to PDF, PDF to Images |
| **Text** | Read Text (Live Text OCR on photos and scanned PDFs), ASCII to Text |
| **Export** | Image (JPEG/HEIC/PNG/TIFF), Video (H.264, HEVC, ProRes 422, GIF, passthrough), Audio (M4A, ALAC, WAV, AIFF), PDF (password, compress), Text |

Plus 10 ready-made workflows, a welcome screen, undo/redo, autosave and ⌘R to render.

## Build

Needs macOS 26+ and Xcode 26+.

```sh
./scripts/build-app.sh        # → build/Toolbox Pro Max.app and build/Toolbox-Pro-Max-<version>.dmg
swift run                     # quick run from source (no icon)
```

The app isn't signed with a paid certificate. The first time, open it from Applications, then
System Settings → Privacy & Security → Open Anyway.

## Self-test

Makes sample media, runs every node on it and writes the results:

```sh
.build/debug/ToolboxProMax --selftest /tmp/tpm-test
.build/debug/ToolboxProMax --selftest /tmp/tpm-test --download "https://www.youtube.com/watch?v=jNQXAC9IVRw"
```

## How it fits together

- `Model/Catalog.swift` defines every node: its ports, settings and what it does.
- `Engine/` holds the processing (`ImageOps`, `Dither`, `ASCII`, `VisionOps`, `VideoOps`, `AudioOps`, `PDFOps`, `Downloader`).
- `Engine/Evaluator.swift` runs the graph and caches each node's result by a fingerprint of its settings and
  everything upstream, so moving a slider only recomputes what comes after it.
- Image effects are closures `(CIImage, scale) -> CIImage`: applied once to a still, or plugged into an
  `AVVideoComposition` for video. `scale` keeps pixel-sized effects identical between preview and render.
- Downloads: yt-dlp is fetched on first use (verified against its published SHA-256) and refreshed weekly.
  Picture and sound come down separately and are joined with AVFoundation, so no ffmpeg is needed.
