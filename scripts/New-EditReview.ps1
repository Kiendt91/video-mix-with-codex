param(
  [Parameter(Mandatory = $true)]
  [string]$ProjectDir,

  [string]$Edl,

  [string]$FinalMp4,

  [string]$QaDir,

  [string]$CandidateAuditDir,

  [string]$OutDir,

  [string]$Title
)

$ErrorActionPreference = "Stop"

function ConvertTo-JsonForHtml($Value) {
  $json = $Value | ConvertTo-Json -Depth 20 -Compress
  return $json.Replace("</", "<\/")
}

function ConvertTo-FileUrl([string]$Path) {
  if (-not $Path) { return $null }
  $resolved = Resolve-Path -LiteralPath $Path -ErrorAction SilentlyContinue
  if (-not $resolved) { return $null }
  return ([System.Uri]$resolved.Path).AbsoluteUri
}

function Read-JsonFile([string]$Path) {
  if (-not $Path) { return $null }
  if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $null }
  return Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json
}

function Find-FirstFile([string[]]$Paths) {
  foreach ($path in $Paths) {
    if ($path -and (Test-Path -LiteralPath $path -PathType Leaf)) {
      return (Resolve-Path -LiteralPath $path).Path
    }
  }
  return $null
}

$project = Resolve-Path -LiteralPath $ProjectDir
if (-not $Edl) {
  $Edl = Join-Path $project "edl.json"
}
if (-not (Test-Path -LiteralPath $Edl -PathType Leaf)) {
  throw "EDL not found. Pass -Edl or place edl.json in ProjectDir."
}

if (-not $QaDir) {
  $QaDir = Join-Path $project "qa"
}
if (-not $OutDir) {
  $OutDir = Join-Path $project "review"
}
New-Item -ItemType Directory -Force -Path $OutDir | Out-Null

if (-not $FinalMp4) {
  $renderDir = Join-Path $project "renders"
  $latest = Get-ChildItem -LiteralPath $renderDir -Filter "*.mp4" -File -ErrorAction SilentlyContinue |
    Sort-Object LastWriteTime -Descending |
    Select-Object -First 1
  if ($latest) {
    $FinalMp4 = $latest.FullName
  }
}

$edlConfig = Read-JsonFile $Edl
$qaSummary = Read-JsonFile (Join-Path $QaDir "qa-summary.json")
$ffprobe = Read-JsonFile (Find-FirstFile @(
    (Join-Path $QaDir "ffprobe-final-exact.json"),
    (Join-Path $QaDir "ffprobe-final.json"),
    (Join-Path $QaDir "ffprobe.json")
  ))
$candidateAudit = if ($CandidateAuditDir) { Read-JsonFile (Join-Path $CandidateAuditDir "candidate-audit.json") } else { $null }

$candidateSheet = if ($CandidateAuditDir) {
  Find-FirstFile @((Join-Path $CandidateAuditDir "candidate-audit-sheet.jpg"))
} else {
  $null
}
$finalSheet = Find-FirstFile @(
  (Join-Path $QaDir "final-exact-frame-contact-sheet.jpg"),
  (Join-Path $QaDir "final-frame-contact-sheet.jpg")
)
$blackdetectPath = Find-FirstFile @(
  (Join-Path $QaDir "blackdetect-final-exact.txt"),
  (Join-Path $QaDir "blackdetect-final.txt"),
  (Join-Path $QaDir "blackdetect.txt")
)
$volumePath = Find-FirstFile @(
  (Join-Path $QaDir "audio\volumedetect-final-exact.txt"),
  (Join-Path $QaDir "audio\volumedetect-final.txt"),
  (Join-Path $QaDir "audio\volumedetect.txt")
)

$blackHits = $null
if ($blackdetectPath) {
  $blackHits = @((Get-Content -LiteralPath $blackdetectPath -Raw) | Select-String -Pattern "black_start" -AllMatches).Matches.Count
}

$meanVolume = $null
$maxVolume = $null
if ($volumePath) {
  $volumeText = Get-Content -LiteralPath $volumePath -Raw
  $meanMatch = [regex]::Match($volumeText, "mean_volume:\s+(-?\d+(?:\.\d+)?) dB")
  $maxMatch = [regex]::Match($volumeText, "max_volume:\s+(-?\d+(?:\.\d+)?) dB")
  if ($meanMatch.Success) { $meanVolume = [double]$meanMatch.Groups[1].Value }
  if ($maxMatch.Success) { $maxVolume = [double]$maxMatch.Groups[1].Value }
}

$reviewTitle = if ($Title) { $Title } elseif ($edlConfig.project.title) { [string]$edlConfig.project.title } else { "Edit Review" }
$projectDuration = if ($edlConfig.project.duration -ne $null) { [double]$edlConfig.project.duration } else { $null }
$formatDuration = if ($qaSummary -and $qaSummary.formatDuration -ne $null) {
  [double]$qaSummary.formatDuration
} elseif ($ffprobe -and $ffprobe.format.duration -ne $null) {
  [double]$ffprobe.format.duration
} else {
  $null
}

$reviewData = [ordered]@{
  title = $reviewTitle
  projectDir = $project.Path
  edlPath = (Resolve-Path -LiteralPath $Edl).Path
  finalMp4 = ConvertTo-FileUrl $FinalMp4
  finalMp4Path = if ($FinalMp4) { (Resolve-Path -LiteralPath $FinalMp4 -ErrorAction SilentlyContinue).Path } else { $null }
  finalContactSheet = ConvertTo-FileUrl $finalSheet
  candidateContactSheet = ConvertTo-FileUrl $candidateSheet
  edl = $edlConfig
  candidateAudit = $candidateAudit
  qa = [ordered]@{
    summary = $qaSummary
    expectedDuration = $projectDuration
    formatDuration = $formatDuration
    blackDetectHits = $blackHits
    meanVolumeDb = $meanVolume
    maxVolumeDb = $maxVolume
    ffprobe = $ffprobe
    blackdetectPath = $blackdetectPath
    volumePath = $volumePath
  }
}

$jsonLiteral = ConvertTo-JsonForHtml $reviewData

$html = @'
<!doctype html>
<html lang="en">
  <head>
    <meta charset="utf-8" />
    <meta name="viewport" content="width=device-width, initial-scale=1" />
    <title>__REVIEW_TITLE__ - Edit Review</title>
    <style>
      :root {
        color-scheme: dark;
        --bg: #101112;
        --panel: #181a1d;
        --panel-2: #202327;
        --line: #343941;
        --text: #f2efe7;
        --muted: #a9adb5;
        --accent: #d9b45f;
        --accent-2: #6fc6b8;
        --risk: #ff937f;
        --ok: #82d28f;
      }
      * { box-sizing: border-box; }
      body {
        margin: 0;
        background: var(--bg);
        color: var(--text);
        font-family: Arial, sans-serif;
      }
      header {
        position: sticky;
        top: 0;
        z-index: 10;
        display: flex;
        align-items: center;
        justify-content: space-between;
        gap: 24px;
        padding: 18px 22px;
        border-bottom: 1px solid var(--line);
        background: rgba(16, 17, 18, 0.94);
      }
      h1, h2, h3, p { margin: 0; }
      h1 { font-size: 22px; line-height: 1.1; }
      h2 { font-size: 15px; margin-bottom: 10px; color: var(--muted); text-transform: uppercase; }
      h3 { font-size: 15px; margin-bottom: 8px; }
      .meta, .qa-grid, .layout, .sheet-grid { display: grid; gap: 12px; }
      .meta { grid-template-columns: repeat(5, auto); align-items: center; color: var(--muted); font-size: 13px; }
      .layout {
        grid-template-columns: minmax(520px, 1.2fr) minmax(360px, 0.8fr);
        padding: 18px;
      }
      .panel {
        background: var(--panel);
        border: 1px solid var(--line);
        border-radius: 8px;
        padding: 14px;
      }
      video {
        width: 100%;
        aspect-ratio: 16 / 9;
        background: #050505;
        border-radius: 6px;
        display: block;
      }
      .timeline {
        margin-top: 14px;
        display: grid;
        gap: 10px;
      }
      .bar {
        position: relative;
        height: 34px;
        border: 1px solid var(--line);
        background: #0c0d0e;
        border-radius: 5px;
        overflow: hidden;
      }
      .segment, .shot {
        position: absolute;
        top: 0;
        height: 100%;
        border-right: 1px solid rgba(255,255,255,0.18);
      }
      .segment {
        background: rgba(111, 198, 184, 0.28);
        color: #e8fff9;
        font-size: 11px;
        padding: 9px 6px;
        white-space: nowrap;
        overflow: hidden;
        text-overflow: ellipsis;
      }
      .shot {
        cursor: pointer;
        background: rgba(217, 180, 95, 0.32);
        transition: background 120ms ease;
      }
      .shot:hover, .shot.active { background: rgba(217, 180, 95, 0.78); }
      .playhead {
        position: absolute;
        top: 0;
        bottom: 0;
        width: 2px;
        background: #fff;
        box-shadow: 0 0 12px rgba(255,255,255,0.8);
      }
      .shot-list {
        display: grid;
        gap: 8px;
        max-height: 520px;
        overflow: auto;
        padding-right: 4px;
      }
      button.shot-row {
        width: 100%;
        border: 1px solid var(--line);
        background: var(--panel-2);
        color: var(--text);
        border-radius: 6px;
        padding: 10px;
        text-align: left;
        cursor: pointer;
      }
      button.shot-row.active { border-color: var(--accent); background: #2a251b; }
      .shot-row .top {
        display: flex;
        justify-content: space-between;
        gap: 10px;
        font-size: 13px;
        margin-bottom: 6px;
      }
      .shot-row .desc { color: var(--muted); font-size: 12px; line-height: 1.35; }
      .qa-grid { grid-template-columns: repeat(4, minmax(0, 1fr)); }
      .qa-card {
        background: var(--panel-2);
        border: 1px solid var(--line);
        border-radius: 6px;
        padding: 10px;
      }
      .qa-card .label { color: var(--muted); font-size: 12px; }
      .qa-card .value { font-size: 18px; margin-top: 4px; }
      .ok { color: var(--ok); }
      .risk { color: var(--risk); }
      .inspector {
        display: grid;
        gap: 8px;
        font-size: 13px;
      }
      .kv { display: grid; grid-template-columns: 130px 1fr; gap: 8px; }
      .kv span:first-child { color: var(--muted); }
      .reason {
        margin-top: 8px;
        padding: 10px;
        background: #111315;
        border: 1px solid var(--line);
        border-radius: 6px;
        color: #dedbd3;
        line-height: 1.45;
      }
      .sheets { padding: 0 18px 18px; }
      .sheet-grid { grid-template-columns: 1fr; }
      img.sheet {
        max-width: 100%;
        border: 1px solid var(--line);
        border-radius: 8px;
        background: #050505;
      }
      a { color: var(--accent-2); }
      @media (max-width: 980px) {
        .layout { grid-template-columns: 1fr; }
        .meta { grid-template-columns: repeat(2, auto); justify-content: start; }
        .qa-grid { grid-template-columns: repeat(2, minmax(0, 1fr)); }
      }
    </style>
  </head>
  <body>
    <header>
      <div>
        <h1 id="title"></h1>
        <div class="meta" id="meta"></div>
      </div>
      <div class="meta" id="links"></div>
    </header>
    <main class="layout">
      <section class="panel">
        <h2>Preview</h2>
        <video id="video" controls preload="metadata"></video>
        <div class="timeline">
          <div class="bar" id="sectionBar"></div>
          <div class="bar" id="shotBar"><div class="playhead" id="playhead"></div></div>
        </div>
      </section>
      <aside class="panel">
        <h2>Shot Inspector</h2>
        <div id="inspector" class="inspector"></div>
      </aside>
      <section class="panel">
        <h2>Shot List</h2>
        <div class="shot-list" id="shotList"></div>
      </section>
      <section class="panel">
        <h2>QA Dashboard</h2>
        <div class="qa-grid" id="qaGrid"></div>
      </section>
    </main>
    <section class="sheets">
      <div class="panel sheet-grid">
        <h2>Contact Sheets</h2>
        <div id="sheets"></div>
      </div>
    </section>
    <script>
      const REVIEW_DATA = __REVIEW_JSON__;
      const edl = REVIEW_DATA.edl || {};
      const project = edl.project || {};
      const shots = edl.shots || [];
      const duration = Number(project.duration || REVIEW_DATA.qa.expectedDuration || 1);
      const video = document.getElementById("video");
      const shotBar = document.getElementById("shotBar");
      const sectionBar = document.getElementById("sectionBar");
      const playhead = document.getElementById("playhead");
      const shotList = document.getElementById("shotList");
      const inspector = document.getElementById("inspector");
      const activeClass = "active";

      document.getElementById("title").textContent = REVIEW_DATA.title || "Edit Review";
      document.getElementById("meta").innerHTML = [
        project.kicker,
        `${Math.round(duration * 1000) / 1000}s`,
        `${project.width || "?"}x${project.height || "?"}`,
        `${project.fps || "?"} fps`,
        project.style
      ].filter(Boolean).map((item) => `<span>${escapeHtml(String(item))}</span>`).join("");
      document.getElementById("links").innerHTML = [
        REVIEW_DATA.finalMp4Path ? `<a href="${REVIEW_DATA.finalMp4}">Final MP4</a>` : "",
        REVIEW_DATA.edlPath ? `<a href="${toFileUrl(REVIEW_DATA.edlPath)}">EDL</a>` : ""
      ].filter(Boolean).join("");
      if (REVIEW_DATA.finalMp4) video.src = REVIEW_DATA.finalMp4;

      function escapeHtml(value) {
        return value.replace(/[&<>"']/g, (char) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" })[char]);
      }
      function toFileUrl(path) {
        return "file:///" + path.replace(/\\/g, "/");
      }
      function pct(value) {
        return `${Math.max(0, Math.min(100, (Number(value) / duration) * 100))}%`;
      }
      function fmt(value) {
        const n = Number(value);
        return Number.isFinite(n) ? `${n.toFixed(3)}s` : "-";
      }
      function findAudit(id) {
        const audit = REVIEW_DATA.candidateAudit || [];
        return audit.find((item) => item.id === id);
      }
      function setActive(index) {
        document.querySelectorAll(".shot, .shot-row").forEach((el) => el.classList.remove(activeClass));
        document.querySelectorAll(`[data-shot-index="${index}"]`).forEach((el) => el.classList.add(activeClass));
        const shot = shots[index];
        if (!shot) return;
        const audit = findAudit(shot.id) || {};
        const riskFlags = audit.riskFlags || [];
        inspector.innerHTML = `
          <div class="kv"><span>ID</span><strong>${escapeHtml(shot.id || `shot-${index + 1}`)}</strong></div>
          <div class="kv"><span>Timeline</span><span>${fmt(shot.timelineStart)} - ${fmt(Number(shot.timelineStart || 0) + Number(shot.duration || 0))}</span></div>
          <div class="kv"><span>Source Start</span><span>${fmt(shot.sourceStart)}</span></div>
          <div class="kv"><span>Duration</span><span>${fmt(shot.duration)}</span></div>
          <div class="kv"><span>Audio Role</span><span>${escapeHtml(shot.audioRole || "muted_visual")}</span></div>
          <div class="kv"><span>Transition</span><span>${escapeHtml(shot.transition || "-")}</span></div>
          <div class="kv"><span>Music Beat</span><span>${escapeHtml(shot.musicBeat || "-")}</span></div>
          <div class="kv"><span>Risk Flags</span><span class="${riskFlags.length ? "risk" : "ok"}">${riskFlags.length ? escapeHtml(riskFlags.join(", ")) : "none"}</span></div>
          <div class="reason">${escapeHtml(shot.storyBeat || "No story beat.")}</div>
          <div class="reason">${escapeHtml(shot.visualRisk || "No visual risk note.")}</div>
        `;
      }
      function seekShot(index) {
        const shot = shots[index];
        if (!shot) return;
        video.currentTime = Number(shot.timelineStart || 0);
        setActive(index);
      }
      function currentShotIndex(time) {
        return Math.max(0, shots.findIndex((shot, index) => {
          const start = Number(shot.timelineStart || 0);
          const end = start + Number(shot.duration || 0);
          const next = shots[index + 1];
          const nextStart = next ? Number(next.timelineStart || end) : end;
          return time >= start && time < Math.max(end, nextStart);
        }));
      }

      (edl.analysis?.song?.sections || []).forEach((section) => {
        const el = document.createElement("div");
        el.className = "segment";
        el.style.left = pct(section.start);
        el.style.width = pct(Number(section.end || 0) - Number(section.start || 0));
        el.textContent = section.label || "section";
        el.title = section.musicCue || "";
        sectionBar.appendChild(el);
      });
      shots.forEach((shot, index) => {
        const bar = document.createElement("button");
        bar.className = "shot";
        bar.dataset.shotIndex = index;
        bar.style.left = pct(shot.timelineStart || 0);
        bar.style.width = pct(shot.duration || 0);
        bar.title = `${shot.id || index + 1}: ${shot.storyBeat || ""}`;
        bar.addEventListener("click", () => seekShot(index));
        shotBar.appendChild(bar);

        const row = document.createElement("button");
        row.className = "shot-row";
        row.dataset.shotIndex = index;
        row.innerHTML = `
          <div class="top"><strong>${escapeHtml(shot.id || `shot-${index + 1}`)}</strong><span>${fmt(shot.timelineStart)} / ${fmt(shot.duration)}</span></div>
          <div class="desc">${escapeHtml(shot.storyBeat || "")}</div>
        `;
        row.addEventListener("click", () => seekShot(index));
        shotList.appendChild(row);
      });
      video.addEventListener("timeupdate", () => {
        playhead.style.left = pct(video.currentTime);
        setActive(currentShotIndex(video.currentTime));
      });

      const qa = REVIEW_DATA.qa || {};
      const blackOk = qa.blackDetectHits === 0 || qa.blackDetectHits === null;
      const durationDelta = Number.isFinite(Number(qa.formatDuration)) && Number.isFinite(Number(qa.expectedDuration))
        ? Math.abs(Number(qa.formatDuration) - Number(qa.expectedDuration))
        : null;
      const qaItems = [
        ["Duration", qa.formatDuration ? `${Number(qa.formatDuration).toFixed(3)}s` : "-", durationDelta === null || durationDelta <= 0.08],
        ["Blackdetect", qa.blackDetectHits === null ? "-" : `${qa.blackDetectHits} hit(s)`, blackOk],
        ["Mean Vol", qa.meanVolumeDb === null ? "-" : `${qa.meanVolumeDb} dB`, true],
        ["Max Vol", qa.maxVolumeDb === null ? "-" : `${qa.maxVolumeDb} dB`, qa.maxVolumeDb === null || qa.maxVolumeDb <= -0.2]
      ];
      document.getElementById("qaGrid").innerHTML = qaItems.map(([label, value, ok]) => `
        <div class="qa-card">
          <div class="label">${label}</div>
          <div class="value ${ok ? "ok" : "risk"}">${value}</div>
        </div>
      `).join("");

      const sheets = [];
      if (REVIEW_DATA.finalContactSheet) sheets.push(["Final QA Frames", REVIEW_DATA.finalContactSheet]);
      if (REVIEW_DATA.candidateContactSheet) sheets.push(["Candidate Audit", REVIEW_DATA.candidateContactSheet]);
      document.getElementById("sheets").innerHTML = sheets.length
        ? sheets.map(([label, src]) => `<h3>${label}</h3><img class="sheet" src="${src}" alt="${label}" />`).join("")
        : `<p>No contact sheet found.</p>`;
      setActive(0);
    </script>
  </body>
</html>
'@

$html = $html.Replace("__REVIEW_TITLE__", ($reviewTitle.Replace("&", "&amp;").Replace("<", "&lt;").Replace(">", "&gt;").Replace('"', "&quot;")))
$html = $html.Replace("__REVIEW_JSON__", $jsonLiteral)

$outFile = Join-Path $OutDir "index.html"
Set-Content -LiteralPath $outFile -Value $html -Encoding utf8

[pscustomobject]@{
  Review = (Resolve-Path -LiteralPath $outFile).Path
  ProjectDir = $project.Path
  FinalMp4 = if ($FinalMp4) { (Resolve-Path -LiteralPath $FinalMp4 -ErrorAction SilentlyContinue).Path } else { $null }
  Edl = (Resolve-Path -LiteralPath $Edl).Path
  QaDir = if (Test-Path -LiteralPath $QaDir) { (Resolve-Path -LiteralPath $QaDir).Path } else { $QaDir }
  CandidateAuditDir = if ($CandidateAuditDir -and (Test-Path -LiteralPath $CandidateAuditDir)) { (Resolve-Path -LiteralPath $CandidateAuditDir).Path } else { $CandidateAuditDir }
} | Format-List
