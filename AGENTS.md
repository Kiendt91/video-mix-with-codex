# Agent Instructions

Use the `music-video-beat-editor`, `hyperframes`, and `hyperframes-cli` skills for this project.

## Goal

Create beat-synced music videos from one music track plus one or more source videos. Prefer deterministic, source-controlled HyperFrames compositions and FFmpeg-normalized shot files.

## Rules

- Do not commit source media or rendered MP4s unless explicitly requested.
- Do not use curtain, slide, left/right wipe, or obvious template transitions for default music-video edits.
- Use one separate `<audio>` clip for music. Keep all `<video>` clips muted.
- Every HyperFrames media clip needs a stable `id`.
- Use `class="clip"`, `data-start`, `data-duration`, and `data-track-index`.
- Do not call `play()`, `pause()`, or manual seek APIs from composition JavaScript.
- Do not use `Date.now()`, unseeded `Math.random()`, or render-time network fetches.
- Re-encode extracted shots with dense keyframes: `-g 30 -keyint_min 30 -sc_threshold 0`.
- Before delivery, run lint, validate, inspect, render, blackdetect, and representative frame extraction.

## Preferred Rhythm

Default music-video cut style:

- Hard cuts on strong beats.
- Short flash/pulse overlays at cut points.
- Longer holds for logo/reveal moments.
- No repeated shot loops unless the song structure intentionally calls back to a previous visual.

