# Workflow

## 1. Ingest

Collect one audio track and one or more source videos. Keep them outside the repo or inside ignored folders such as `source/` or `media/`.

Probe each file:

```powershell
ffprobe -hide_banner -v error -show_format -show_streams -of json path\to\file.mp4
```

Record duration, resolution, fps, codec, and whether the source has burned-in subtitles or logos.

## 2. Find the Beat

For a fast first pass, estimate BPM and place cuts on strong musical accents. For a professional pass, manually adjust the beat grid after listening.

Use phrase-level structure:

- intro
- lift
- drop
- mid-section
- final logo or resolve

## 3. Select Shots

Make contact sheets or snapshot probes from source footage. Mark each usable range with:

- source file
- source start time
- duration
- subject
- energy level
- risk notes such as subtitles, dark frames, low resolution, or repeat imagery

Avoid selecting multiple shots that show the same content unless the repetition is intentional.

## 4. Build the EDL

Use `examples/edl.example.json` as the schema. The EDL defines:

- project dimensions and fps
- audio trim and duration
- each shot source, source start, timeline start, duration
- title text
- cut flash colors

## 5. Generate the Project

Run:

```powershell
.\scripts\New-VideoMixProject.ps1 -Edl .\examples\edl.example.json -OutDir D:\video-renders\my-mix
```

The script:

- creates a HyperFrames project folder
- extracts each shot to `media/shot-XX.mp4`
- exports a trimmed music file to `media/music.mp3`
- writes `index.html` from the template
- copies `gsap.min.js` if a local path is provided

## 6. Render and QA

Run:

```powershell
.\scripts\Render-VideoMix.ps1 -ProjectDir D:\video-renders\my-mix
.\scripts\Test-VideoMix.ps1 -ProjectDir D:\video-renders\my-mix
```

Do not deliver until blackdetect is clean and the extracted QA frames show no black frames, broken text, unintended subtitles, or rough transitions.

