param(
  [Parameter(Mandatory = $true)]
  [string]$ProjectDir,

  [string]$Output = "renders\final.mp4",

  [int]$Fps,

  [string]$Quality,

  [string]$SnapshotAt = "0.5,3.1,6.1,9.1,12.1,15.1,18.1,21.1,24.1",

  [switch]$SkipSnapshots,

  [switch]$RunQa,

  [string]$Edl
)

$ErrorActionPreference = "Stop"
$project = Resolve-Path -LiteralPath $ProjectDir
Push-Location $project
try {
  npx hyperframes lint
  if ($LASTEXITCODE -ne 0) { throw "hyperframes lint failed." }

  npx hyperframes validate
  if ($LASTEXITCODE -ne 0) { throw "hyperframes validate failed." }

  npx hyperframes inspect
  if ($LASTEXITCODE -ne 0) { throw "hyperframes inspect failed." }

  if (-not $SkipSnapshots) {
    New-Item -ItemType Directory -Force -Path "snapshots" | Out-Null
    npx hyperframes snapshot --at $SnapshotAt
    if ($LASTEXITCODE -ne 0) { throw "hyperframes snapshot failed." }
  }

  $renderArgs = @("hyperframes", "render", "--output", $Output)
  if ($Fps) {
    $renderArgs += @("--fps", [string]$Fps)
  }
  if ($Quality) {
    $renderArgs += @("--quality", $Quality)
  }

  npx @renderArgs
  if ($LASTEXITCODE -ne 0) { throw "hyperframes render failed." }

  if ($RunQa) {
    $qaArgs = @{
      ProjectDir = $project.Path
      FinalMp4 = (Join-Path $project.Path $Output)
      CreateContactSheet = $true
      FailOnBlackFrames = $true
    }
    if ($Edl) { $qaArgs.Edl = $Edl }
    & (Join-Path $PSScriptRoot "Test-VideoMix.ps1") @qaArgs
  }
} finally {
  Pop-Location
}
