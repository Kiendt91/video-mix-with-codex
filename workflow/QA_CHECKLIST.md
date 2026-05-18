# QA Checklist

## Before Render

- [ ] Every `<video>` and `<audio>` clip has a stable `id`.
- [ ] All video clips are muted and `playsinline`.
- [ ] Music is a separate `<audio>` element.
- [ ] No source media is referenced through missing or temporary paths.
- [ ] Extracted shots are normalized to target resolution and fps.
- [ ] Extracted shots use dense keyframes.
- [ ] No obvious subtitles or unwanted source overlays in selected shots.

## HyperFrames Checks

```powershell
npx hyperframes lint
npx hyperframes validate
npx hyperframes inspect
npx hyperframes snapshot --at 0.5,3.1,6.1,9.1,12.1,15.1,18.1,21.1,24.1
npx hyperframes render
```

## Final MP4 Checks

```powershell
ffprobe -hide_banner -v error -show_entries format=duration:stream=codec_type,width,height,r_frame_rate -of default=nw=1 final.mp4
ffmpeg -hide_banner -i final.mp4 -vf "blackdetect=d=0.08:pix_th=0.08" -an -f null -
```

Extract representative frames at:

- first visible frame
- just before and after each major cut
- middle of every longer hold
- final resolve

Do not deliver if black frames, silence, frozen clips, broken text, unintended subtitles, or rough template transitions remain.

## Cinematic Character Extra Checks

- [ ] Dialogue is intelligible over music.
- [ ] Subtitle timing matches the spoken line.
- [ ] Subtitle text does not cover important faces or hands.
- [ ] Each section advances the character arc.
- [ ] The final third contains the emotional peak or visual payoff.
- [ ] No source subtitle conflicts with the custom subtitle layer.
