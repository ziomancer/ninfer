#Requires -Version 5.1
<#
  Make-Bundle.ps1 -- package the NInfer->Hermes stack for another machine.

  Produces a folder (NOT a zip -- PS 5.1 zip mishandles >4 GiB entries; transfer
  the folder with robocopy/scp/tailscale drive) containing:

    ninfer-image.tar     docker save of ninfer:local -- bit-identical engine.
                         ~1.7 GB (OCI export, compressed blobs) under the
                         containerd store; up to ~4.7 GB under the legacy store.
    ops overlay          docker-compose.yml, VH-Model.ps1, .env.example, CUTOVER.md,
                         bench.sh, RESULTS.md, check-collapse.sh, PORTABLE.md
    <artifacts>          only with -IncludeArtifacts; default is download-on-target
    MANIFEST.txt         image id + SHA-256 of every bundled file

  Usage:
    .\Make-Bundle.ps1                          # bundle without model artifacts
    .\Make-Bundle.ps1 -IncludeArtifacts nvfp4  # also copy the 20 GiB artifact
    .\Make-Bundle.ps1 -OutDir D:\transfer
#>
param(
    [string]$OutDir = (Join-Path $env:USERPROFILE "ninfer-bundle"),
    [ValidateSet("none","groupwise","nvfp4","both")]
    [string]$IncludeArtifacts = "none"
)

$ErrorActionPreference = "Stop"
$RepoRoot = Split-Path -Parent $PSScriptRoot
$Stamp    = Get-Date -Format "yyyyMMdd-HHmm"
$Bundle   = Join-Path $OutDir "ninfer-portable-$Stamp"

# -- Preconditions ------------------------------------------------------------
$img = docker image ls ninfer:local --format '{{.ID}}|{{.CreatedAt}}|{{.Size}}'
if (-not $img) { throw "Image ninfer:local not found. Nothing to bundle." }
$imgId, $imgCreated, $imgSize = $img.Split("|")

if (-not (Test-Path (Join-Path $RepoRoot ".env.example"))) {
    throw ".env.example missing from repo root -- the target has no config template without it."
}

New-Item -ItemType Directory -Force $Bundle | Out-Null
Write-Host "Bundling into $Bundle" -ForegroundColor Cyan
Write-Host "  image ninfer:local  $imgId  $imgSize  (created $imgCreated)"

# -- 1. Engine image (the slow part) -----------------------------------------
$tar = Join-Path $Bundle "ninfer-image.tar"
Write-Host "  docker save -> ninfer-image.tar (takes a few minutes) ..."
docker save ninfer:local -o $tar
if ($LASTEXITCODE -ne 0) { throw "docker save failed" }

# -- 2. Ops overlay files -----------------------------------------------------
# Explicit list, NOT directory copies: on the vigil-deploy branch, bench/ and
# tools/ also hold the upstream engine source tree, which the target gets from
# the fork (or doesn't need at all) — only the ops overlay travels in the bundle.
# Deliberately NOT .env (per-host secrets) and NOT logs/ (host history).
$files = @(
    "docker-compose.yml", "VH-Model.ps1", ".env.example", "CUTOVER.md",
    "bench\bench.sh", "bench\RESULTS.md",
    "tools\check-collapse.sh",
    "deploy\PORTABLE.md"
)
foreach ($f in $files) {
    $dst = Join-Path $Bundle $f
    New-Item -ItemType Directory -Force (Split-Path -Parent $dst) | Out-Null
    Copy-Item (Join-Path $RepoRoot $f) $dst
}

# -- 3. Optional artifacts ----------------------------------------------------
$modelsDir = $null
$envFile = Join-Path $RepoRoot ".env"
if (Test-Path $envFile) {
    $m = Select-String -Path $envFile -Pattern '^\s*NINFER_MODELS_DIR\s*=\s*(.+?)\s*$' | Select-Object -First 1
    if ($m) { $modelsDir = $m.Matches[0].Groups[1].Value }
}
if (-not $modelsDir) { $modelsDir = Join-Path $env:USERPROFILE ".ninfer\models" }

$artifactMap = @{
    "groupwise" = "qwen3_8_27b.ninfer"
    "nvfp4"     = "qwen3_8_27b_nvfp4.ninfer"
}
$wanted = switch ($IncludeArtifacts) {
    "none"  { @() }
    "both"  { $artifactMap.Values }
    default { @($artifactMap[$IncludeArtifacts]) }
}
foreach ($a in $wanted) {
    $src = Join-Path $modelsDir $a
    if (-not (Test-Path -LiteralPath $src)) { throw "Artifact not on disk: $src" }
    Write-Host "  copying $a (this is 17-20 GiB) ..."
    Copy-Item -LiteralPath $src $Bundle
}
if ($IncludeArtifacts -eq "none") {
    Write-Host "  (artifacts excluded -- target downloads from HuggingFace, hashes in deploy\PORTABLE.md)"
}

# -- 4. Manifest --------------------------------------------------------------
Write-Host "  hashing bundle contents ..."
$manifest = Join-Path $Bundle "MANIFEST.txt"
@(
    "NInfer portable bundle  $Stamp"
    "origin host: $env:COMPUTERNAME"
    "image: ninfer:local  id=$imgId  size=$imgSize  created=$imgCreated"
    ""
    "SHA-256:"
) | Set-Content $manifest -Encoding utf8
Get-ChildItem $Bundle -Recurse -File | Where-Object { $_.FullName -ne $manifest } | ForEach-Object {
    $h = (Get-FileHash $_.FullName -Algorithm SHA256).Hash.ToLower()
    $rel = $_.FullName.Substring($Bundle.Length + 1)
    Add-Content $manifest ("  {0}  {1}" -f $h, $rel) -Encoding utf8
}

$total = (Get-ChildItem $Bundle -Recurse -File | Measure-Object Length -Sum).Sum / 1GB
Write-Host ""
Write-Host ("Done. {0:N2} GB at {1}" -f $total, $Bundle) -ForegroundColor Green
Write-Host "Transfer the FOLDER as-is (robocopy /MT, scp -r, tailscale drive)."
Write-Host "Do not Compress-Archive it: PS 5.1 zip breaks on >4 GiB entries."
Write-Host "On the target, start at deploy\PORTABLE.md step 0."
