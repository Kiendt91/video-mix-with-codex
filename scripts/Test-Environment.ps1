param(
  [string]$GsapPath
)

$ErrorActionPreference = "Stop"

function Test-CommandAvailable([string]$Name, [string[]]$Args = @("--version")) {
  $cmd = Get-Command $Name -ErrorAction SilentlyContinue
  if (-not $cmd) {
    return [pscustomobject]@{
      Tool = $Name
      Status = "missing"
      Detail = "Not found on PATH"
    }
  }

  $detail = $cmd.Source
  if ($Args.Count -gt 0) {
    try {
      $output = & $Name @Args 2>&1 | Select-Object -First 1
      if ($output) { $detail = "$detail ($output)" }
    } catch {
      $detail = "$detail (version check failed: $($_.Exception.Message))"
    }
  }

  [pscustomobject]@{
    Tool = $Name
    Status = "ok"
    Detail = $detail
  }
}

$checks = @(
  (Test-CommandAvailable "ffmpeg" @("-version")),
  (Test-CommandAvailable "ffprobe" @("-version")),
  (Test-CommandAvailable "node" @("--version")),
  (Test-CommandAvailable "npx" @("--version"))
)

$hyperframesStatus = "unknown"
$hyperframesDetail = "Run manually: npx hyperframes --version"
try {
  $output = npx hyperframes --version 2>&1 | Select-Object -First 1
  if ($LASTEXITCODE -eq 0 -or $output -match '^\d+\.\d+\.\d+') {
    $hyperframesStatus = "ok"
    $hyperframesDetail = [string]$output
  } else {
    $hyperframesStatus = "warning"
    $hyperframesDetail = [string]$output
  }
} catch {
  $hyperframesStatus = "warning"
  $hyperframesDetail = $_.Exception.Message
}

$checks += [pscustomobject]@{
  Tool = "hyperframes"
  Status = $hyperframesStatus
  Detail = $hyperframesDetail
}

if ($GsapPath) {
  $checks += [pscustomobject]@{
    Tool = "gsap.min.js"
    Status = if (Test-Path -LiteralPath $GsapPath) { "ok" } else { "missing" }
    Detail = $GsapPath
  }
}

$checks | Format-Table -AutoSize

$missing = @($checks | Where-Object { $_.Status -eq "missing" })
if ($missing.Count -gt 0) {
  throw "Environment check failed: $($missing.Tool -join ', ') missing."
}

Write-Host "Environment check completed."
