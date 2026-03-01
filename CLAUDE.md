# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Build & Deploy

```bash
swift build                # Build debug binary
bash build.sh              # Build, codesign, copy to /Applications/Mistglow.app, launch
```

`build.sh` preserves TCC (Screen Recording) permission grants by updating the binary in-place rather than replacing the app bundle. Code signing identity: "MiSTerCast Dev".

No test suite exists. Verify changes by building and running the app.

## Architecture

Mistglow is a macOS 14+ SwiftUI app that streams video/audio to a MiSTer FPGA over the Groovy protocol (UDP port 32100). Two streaming modes:

1. **Desktop** — captures a Mac display via `CGDisplayCreateImage`, audio via ScreenCaptureKit
2. **Plex** — receives cast commands from Plex clients, decodes media with two FFmpeg subprocesses (video BGR24 + audio PCM s16le), feeds frames/audio to StreamEngine

### Key Components

- **AppState** (`App/AppState.swift`) — `@MainActor @Observable` central state. All UI binds here.
- **StreamEngine** (`Streaming/StreamEngine.swift`) — orchestrates capture→compress→transmit at 60Hz. Supports both internal capture and external frame/audio sources (Plex). Uses `DispatchSourceTimer`, not async/await.
- **GroovyConnection** (`Protocol/GroovyConnection.swift`) — UDP socket via Network framework. Commands: INIT (0x02), SWITCHRES (0x03), AUDIO (0x04), BLIT_FIELD_VSYNC (0x07). MTU 1472 bytes.
- **FrameTransmitter** — Swift actor that slices frames into UDP packets with LZ4/delta compression.
- **PlexPlaybackController** (`Plex/PlexPlaybackController.swift`) — `@Observable` state machine coordinating GDM discovery, companion server, FFmpeg renderer, and play queue.
- **PlexAVPlayerRenderer** (`Plex/PlexAVPlayerRenderer.swift`) — launches two FFmpeg `Process` instances (video + audio) from the same seek offset. Pause/resume via SIGSTOP/SIGCONT. `_seekGeneration` counter prevents stale threads from firing callbacks after seek.
- **PlexCompanionServer** (`Plex/PlexCompanionServer.swift`) — HTTP server on port 3005 implementing Plex companion protocol (XML). Handles play/pause/seek/skip/stop commands.
- **PlexGDMAdvertiser** (`Plex/PlexGDMAdvertiser.swift`) — UDP multicast listener on 239.0.0.250:32412. Responds to M-SEARCH with device info so Plex clients discover "MiSTer".

### Threading Model

- `@MainActor`: AppState, PlexPlaybackController, all SwiftUI views
- `@unchecked Sendable` with manual locks: StreamEngine, PlexAVPlayerRenderer, GroovyConnection
- Swift actor: FrameTransmitter
- Background `Thread.detachNewThread`: FFmpeg pipe readers (video frames, audio PCM)
- DispatchQueues: streamQueue (capture loop), audioQueue (audio send timer)

### Pixel Format

FPGA expects RGB byte order. `CGContext` with `noneSkipFirst | byteOrder32Little` produces `[B,G,R,X]` in memory. Direct copy of bytes 0,1,2 gives correct RGB — no byte swap needed. FFmpeg video output uses `bgr24` pixel format to match.

## Conventions

- Settings auto-save to `~/Library/Application Support/Mistglow/` via `Codable` `AppSettings`
- App installs to `/Applications/Mistglow.app` for stable Screen Recording permissions
- Modeline presets defined in `Protocol/Modeline.swift` (NTSC/PAL, 240p through 576i)
- UI uses custom glass morphism modifiers (`glassButton`, `glassTab`, `glassHover`) defined in `Views/GlassCompat.swift`
- Plex FFmpeg requires `/opt/homebrew/bin/ffmpeg`, `/usr/local/bin/ffmpeg`, or `/usr/bin/ffmpeg`
- INIT packet must be exactly 5 bytes (cmd, compression, sampleRate, channels, rgbMode)
