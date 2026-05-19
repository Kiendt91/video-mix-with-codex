param(
  [Parameter(Mandatory = $true)]
  [string]$WorkDir,

  [string]$Sources,

  [string]$MusicUrl,

  [string]$MusicPath,

  [string]$Edl,

  [ValidateSet("Beat", "Cinematic")]
  [string]$Mode = "Cinematic",

  [string]$ProjectDir,

  [string]$GsapPath,

  [switch]$Render,

  [string]$RenderOutput = "renders\final.mp4",

  [switch]$CreateReview,

  [switch]$UseOcr,

  [switch]$SkipSourceAudit,

  [switch]$SkipCandidateAudit,

  [switch]$Force
)

$ErrorActionPreference = "Stop"

function Resolve-OptionalPath([string]$Path) {
  if (-not $Path) { return $null }
  return (Resolve-Path -LiteralPath $Path).Path
}

New-Item -ItemType Directory -Force -Path $WorkDir | Out-Null
$work = Resolve-Path -LiteralPath $WorkDir
$auditDir = Join-Path $work "audit"
$metadataDir = Join-Path $auditDir "metadata"
$musicDir = Join-Path $work "music"
New-Item -ItemType Directory -Force -Path $auditDir, $metadataDir, $musicDir | Out-Null

$musicFile = $MusicPath
if ($MusicUrl) {
  if (-not (Get-Command yt-dlp -ErrorAction SilentlyContinue) -and -not (Get-Command python -ErrorAction SilentlyContinue)) {
    throw "yt-dlp or python was not found. Install yt-dlp or pass -MusicPath."
  }
  $musicTemplate = Join-Path $musicDir "%(title).80s-%(id)s.%(ext)s"
  if (Get-Command yt-dlp -ErrorAction SilentlyContinue) {
    yt-dlp -f "bestaudio/best" -o $musicTemplate $MusicUrl
  } else {
    python -m yt_dlp -f "bestaudio/best" -o $musicTemplate $MusicUrl
  }
  if ($LASTEXITCODE -ne 0) { throw "Music download failed." }
  $musicFile = (Get-ChildItem -LiteralPath $musicDir -File | Sort-Object LastWriteTime -Descending | Select-Object -First 1).FullName
  if (-not $musicFile) { throw "Music download did not produce a file." }
}

if ($musicFile) {
  $musicProbe = Join-Path $metadataDir "music.ffprobe.json"
  & (Join-Path $PSScriptRoot "Analyze-Media.ps1") -Path $musicFile -OutJson $musicProbe
}

if ($Sources -and -not $SkipSourceAudit) {
  $sourceProbe = Join-Path $metadataDir "sources.ffprobe.json"
  & (Join-Path $PSScriptRoot "Analyze-Media.ps1") -Path $Sources -OutJson $sourceProbe

  $sheetsDir = Join-Path $auditDir "source-sheets"
  & (Join-Path $PSScriptRoot "New-ContactSheet.ps1") -Path $Sources -OutDir $sheetsDir -IntervalSec 8

  $sheetsDenseDir = Join-Path $auditDir "source-sheets-6s"
  & (Join-Path $PSScriptRoot "New-ContactSheet.ps1") -Path $Sources -OutDir $sheetsDenseDir -IntervalSec 6
}

if (-not $Edl) {
  [pscustomobject]@{
    status = "prepared"
    workDir = $work.Path
    music = $musicFile
    audit = $auditDir
    nextStep = "Create or pass -Edl, then rerun this script to generate/render/QA."
  } | Format-List
  return
}

$edlPath = Resolve-OptionalPath $Edl
& (Join-Path $PSScriptRoot "Validate-Edl.ps1") -Edl $edlPath

if (-not $SkipCandidateAudit) {
  $candidateDir = Join-Path $auditDir "candidates"
  $candidateArgs = @{
    Edl = $edlPath
    OutDir = $candidateDir
  }
  if ($UseOcr) { $candidateArgs.UseOcr = $true }
  & (Join-Path $PSScriptRoot "New-CandidateAudit.ps1") @candidateArgs
} else {
  $candidateDir = Join-Path $auditDir "candidates"
}

if (-not $ProjectDir) {
  $ProjectDir = Join-Path $work ("project-" + $Mode.ToLowerInvariant())
}

$generator = if ($Mode -eq "Beat") { "New-VideoMixProject.ps1" } else { "New-CinematicEditProject.ps1" }
$generateArgs = @{
  Edl = $edlPath
  OutDir = $ProjectDir
}
if ($GsapPath) { $generateArgs.GsapPath = $GsapPath }
if ($Force) { $generateArgs.Force = $true }
& (Join-Path $PSScriptRoot $generator) @generateArgs

if ($Render) {
  & (Join-Path $PSScriptRoot "Render-VideoMix.ps1") -ProjectDir $ProjectDir -Output $RenderOutput -SkipSnapshots
  $finalMp4 = Join-Path (Resolve-Path -LiteralPath $ProjectDir) $RenderOutput
  & (Join-Path $PSScriptRoot "Test-VideoMix.ps1") -ProjectDir $ProjectDir -FinalMp4 $finalMp4 -Edl $edlPath -CreateContactSheet -FailOnBlackFrames
}

if ($CreateReview) {
  $reviewArgs = @{
    ProjectDir = $ProjectDir
    Edl = $edlPath
  }
  if ($Render) {
    $reviewArgs.FinalMp4 = (Join-Path (Resolve-Path -LiteralPath $ProjectDir) $RenderOutput)
  }
  if (Test-Path -LiteralPath $candidateDir) {
    $reviewArgs.CandidateAuditDir = $candidateDir
  }
  & (Join-Path $PSScriptRoot "New-EditReview.ps1") @reviewArgs
}

[pscustomobject]@{
  status = if ($Render) { "rendered" } else { "project-created" }
  workDir = $work.Path
  edl = $edlPath
  projectDir = (Resolve-Path -LiteralPath $ProjectDir).Path
  audit = $auditDir
  renderOutput = if ($Render) { (Join-Path (Resolve-Path -LiteralPath $ProjectDir) $RenderOutput) } else { $null }
} | Format-List
