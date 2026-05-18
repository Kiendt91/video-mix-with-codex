# Video Mix With Codex

Reusable workflow for making beat-synced music videos with Codex, FFmpeg, and HyperFrames.

This repo packages the editing process we used: analyze the song, choose strong moments from source videos, cut on musical beats or emotional dialogue beats, avoid obvious curtain/wipe transitions, render with HyperFrames, then run mandatory QA.

## What This Is

- A repeatable music-video editing workflow.
- HyperFrames composition template for hard cuts plus subtle beat flashes.
- Cinematic character-edit mode for dialogue-led tribute videos.
- PowerShell scripts for media probing, shot extraction, rendering, vertical conversion, and QA.
- Example EDL schema you can copy for a new project.

## What This Is Not

- It does not include source videos or music.
- It does not upload rendered MP4s by default.
- It does not depend on a specific Warhammer project; that was only the first test case.

## Requirements

- Windows PowerShell
- FFmpeg and FFprobe on `PATH`
- Node.js 22+
- HyperFrames CLI through `npx hyperframes`

Optional:

- Bun, if you are working inside the HyperFrames monorepo.

## Quick Start

### Beat-Cut Music Video

1. Copy `examples/edl.example.json` to your own project folder.
2. Update `audio.path` and each shot `source` path.
3. Run:

```powershell
.\scripts\New-VideoMixProject.ps1 -Edl .\examples\edl.example.json -OutDir D:\video-renders\my-mix
.\scripts\Render-VideoMix.ps1 -ProjectDir D:\video-renders\my-mix
.\scripts\Test-VideoMix.ps1 -ProjectDir D:\video-renders\my-mix
```

### Cinematic Character Edit

Use this for tribute-style videos driven by dialogue and emotional arc.

1. Copy `examples/cinematic-character-edl.example.json`.
2. Fill in `shots`, `dialogue`, and `captions`.
3. Run:

```powershell
.\scripts\New-CinematicEditProject.ps1 -Edl .\examples\cinematic-character-edl.example.json -OutDir D:\video-renders\my-character-edit
.\scripts\Render-VideoMix.ps1 -ProjectDir D:\video-renders\my-character-edit -SnapshotAt "0.5,5.5,12,24,36,48,58"
.\scripts\Test-VideoMix.ps1 -ProjectDir D:\video-renders\my-character-edit -Times "0.5,5.5,12,24,36,48,58"
```

For TikTok/Shorts output after a landscape render:

```powershell
.\scripts\New-VerticalVersion.ps1 -InputMp4 D:\video-renders\my-mix\renders\final.mp4 -OutputMp4 D:\video-renders\my-mix\renders\final_vertical.mp4
```

## Editing Principles

- Cut on real musical accents, not equal durations.
- Keep fewer, stronger shots before adding more effects.
- Prefer hard cuts, short light flashes, impact pulses, and subtle grade changes.
- Avoid curtain, slide, left/right wipe, and obvious template transitions unless the content explicitly needs them.
- Avoid looping the same image pool; unique shot selection matters more than transition complexity.
- Normalize every extracted shot to the target frame size, fps, codec, and dense keyframes before rendering.
- For cinematic character edits, dialogue clarity beats visual complexity.
- For cinematic character edits, use invisible transitions, long emotional holds, clean subtitle cues, and ultrawide framing.

## Repo Layout

```text
scripts/
  New-CinematicEditProject.ps1  Build dialogue-led cinematic edit from an EDL.
  New-VideoMixProject.ps1   Build HyperFrames project from an EDL.
  Render-VideoMix.ps1       Lint, validate, inspect, snapshot, render.
  Test-VideoMix.ps1         FFprobe + blackdetect + QA frame extraction.
  New-VerticalVersion.ps1   Convert landscape render to 1080x1920.
templates/
  hyperframes/index.template.html
  hyperframes/cinematic-character.template.html
workflow/
  CINEMATIC_CHARACTER_EDIT.md
  WORKFLOW.md
  STYLE_GUIDE.md
  QA_CHECKLIST.md
examples/
  edl.example.json
```
