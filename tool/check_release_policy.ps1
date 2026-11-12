[CmdletBinding()]
param(
  [string]$RepoRoot
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if ([string]::IsNullOrWhiteSpace($RepoRoot)) {
  $RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
}

function Read-RepoFile {
  param([Parameter(Mandatory = $true)][string]$RelativePath)

  $path = Join-Path $RepoRoot $RelativePath
  if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
    throw "Missing required file: $RelativePath"
  }
  return Get-Content -LiteralPath $path -Raw -Encoding UTF8
}

$failures = [System.Collections.Generic.List[string]]::new()

function Require-Text {
  param(
    [Parameter(Mandatory = $true)][string]$RelativePath,
    [Parameter(Mandatory = $true)][string]$Content,
    [Parameter(Mandatory = $true)][string]$Needle,
    [Parameter(Mandatory = $true)][string]$Reason
  )

  if (-not $Content.Contains($Needle)) {
    $failures.Add("${RelativePath}: missing '$Needle' ($Reason)")
  }
}

function Forbid-Pattern {
  param(
    [Parameter(Mandatory = $true)][string]$RelativePath,
    [Parameter(Mandatory = $true)][string]$Content,
    [Parameter(Mandatory = $true)][string]$Pattern,
    [Parameter(Mandatory = $true)][string]$Reason
  )

  if ($Content -match $Pattern) {
    $failures.Add("${RelativePath}: forbidden pattern '$Pattern' ($Reason)")
  }
}

# my-comic is Windows-only: release-desktop.yml is the single desktop publisher.
$workflowPaths = @(
  '.github/workflows/release-desktop.yml'
)

foreach ($relativePath in $workflowPaths) {
  $content = Read-RepoFile $relativePath

  Require-Text $relativePath $content 'concurrency:' 'release publishers must serialize same-tag runs'
  Require-Text $relativePath $content 'group: mycomic-release-${{ github.workflow }}-${{ github.event_name == ''push'' && github.ref || github.event.release.tag_name || github.event.inputs.tag_name || github.sha }}' 'push publishes serialize per branch and same-tag dispatches serialize within the workflow'
  Require-Text $relativePath $content 'cancel-in-progress: false' 'a running publish must not be cancelled'
  Require-Text $relativePath $content 'fetch-depth: 0' 'release sequence uses full git history'
  Require-Text $relativePath $content 'RELEASE_SEQUENCE=$(bash tool/release_sequence.sh)' 'release sequence must come from the shared script'
  Require-Text $relativePath $content 'release_sequence=$RELEASE_SEQUENCE' 'build steps must consume the shared release sequence'

  # 裸算式绕过地板：新增一处 rev-list 赋值就足以把序号打回倒退态。
  Forbid-Pattern $relativePath $content 'RELEASE_SEQUENCE=\$\(git rev-list' 'release sequence must go through tool/release_sequence.sh (the one-time floor); a bare rev-list count regresses after any history rewrite'
  Forbid-Pattern $relativePath $content '\bGITHUB_RUN_NUMBER\b' 'workflow-local run_number splits same-version releases'
  Forbid-Pattern $relativePath $content 'github\.run_number' 'workflow-local run_number splits build numbers across release workflows'

  # TODO-705: forbid a HARDCODED make_latest:true literal so a push/debug/beta
  # workflow can never promote a Latest release.
  Forbid-Pattern $relativePath $content 'make_latest:\s*true\b' 'a hardcoded make_latest:true would force a Latest release on push/debug/beta; use the channel output (release-channel hard rule)'
}

# TODO-705: the desktop workflow must publish the mirror update manifest
# (latest-<channel>.json) so beta/debug in-China update checks succeed.
$manifestScript = Read-RepoFile 'tool/publish_update_manifest.sh'
Require-Text 'tool/publish_update_manifest.sh' $manifestScript 'releases/download/' 'manifest asset URLs must be releases/download/<tag>/<name> (TODO-705)'
Forbid-Pattern 'tool/publish_update_manifest.sh' $manifestScript 'make_latest' 'the mirror manifest is a data file on a git branch, not a GitHub Release; it must never set make_latest (TODO-705)'
Forbid-Pattern 'tool/publish_update_manifest.sh' $manifestScript '\brun_number\b' 'manifest sequence must be the shared git release sequence, never a workflow run_number (TODO-705)'
Require-Text 'tool/publish_update_manifest.sh' $manifestScript 'DOWNLOAD_TAG' 'manifest download URLs must resolve under the actual release tag (DOWNLOAD_TAG), decoupled from the versioned manifest tag (TODO-1049)'

# The mirror whitelist must be Windows-only: my-comic ships only a Windows
# installer, and an APK/IPA/macOS entry would be dead weight for the client.
Require-Text 'tool/publish_update_manifest.sh' $manifestScript 'suffixes = ("-windows-setup.exe",)' 'the mirror asset whitelist must contain only the Windows installer'

foreach ($relativePath in $workflowPaths) {
  $content = Read-RepoFile $relativePath
  Require-Text $relativePath $content 'tool/publish_update_manifest.sh' 'release workflows must publish the mirror update manifest (TODO-705)'
  Require-Text $relativePath $content 'RELEASE_SEQUENCE: ${{ steps.channel.outputs.release_sequence }}' 'manifest publisher must consume the shared release sequence, not run_number (TODO-705)'
  Require-Text $relativePath $content 'tag_name: ${{ steps.channel.outputs.publish_tag }}' 'the managed release must publish under publish_tag (rolling `debug-rolling` for debug), not the versioned tag (TODO-1049)'
  Require-Text $relativePath $content 'PUBLISH_TAG="$ROLLING_DEBUG_TAG"' 'debug channel PUBLISH_TAG must be the rolling tag so debug prereleases stop accumulating (TODO-1049)'
  Require-Text $relativePath $content 'DOWNLOAD_TAG: ${{ steps.channel.outputs.publish_tag }}' 'manifest publisher must form asset URLs under the actual release tag (publish_tag), not the versioned tag (TODO-1049)'
  Require-Text $relativePath $content 'echo "tag=$TAG"' 'the versioned tag must still be emitted so the manifest `tag` field drives client version comparison (TODO-1049)'
}

# TODO-1049 + BUG-1481: the rolling debug tag must be a fixed, product-scoped
# literal. A computed tag reintroduces one prerelease per push; the bare
# historical `debug-rolling` is frozen for the app.hibiki.reader family.
foreach ($relativePath in $workflowPaths) {
  $content = Read-RepoFile $relativePath
  $found = [regex]::Matches($content, 'ROLLING_DEBUG_TAG=(\S+)')
  if ($found.Count -eq 0) {
    $failures.Add("${relativePath}: missing a ROLLING_DEBUG_TAG assignment (the debug channel must publish to one fixed rolling release tag, TODO-1049)")
    continue
  }
  $values = @($found | ForEach-Object { $_.Groups[1].Value } | Sort-Object -Unique)
  if ($values.Count -ne 1) {
    $failures.Add("${relativePath}: ROLLING_DEBUG_TAG is assigned conflicting values ($($values -join ', ')); all debug jobs in one workflow must publish to the same rolling release (TODO-1049)")
    continue
  }
  $tag = $values[0]
  if ($tag -notmatch '^[A-Za-z0-9._-]+$') {
    $failures.Add("${relativePath}: ROLLING_DEBUG_TAG='$tag' is not a fixed literal; a computed tag reintroduces one prerelease per push (TODO-1049)")
  }
  if (-not $tag.EndsWith('debug-rolling')) {
    $failures.Add("${relativePath}: ROLLING_DEBUG_TAG='$tag' must end with 'debug-rolling' so the rolling debug release stays recognizable (TODO-1049)")
  }
  if ($tag -eq 'debug-rolling') {
    $failures.Add("${relativePath}: ROLLING_DEBUG_TAG='debug-rolling' is frozen for the app.hibiki.reader family; MyComic must use a product-scoped rolling tag (BUG-1481)")
  }
}

# Windows desktop release invariants.
$desktopWorkflow = Read-RepoFile '.github/workflows/release-desktop.yml'
Require-Text '.github/workflows/release-desktop.yml' $desktopWorkflow '--build-number "${{ steps.channel.outputs.release_sequence }}"' 'desktop build number must use the shared release sequence'
Require-Text '.github/workflows/release-desktop.yml' $desktopWorkflow 'flutter build windows --release' 'desktop workflow must still publish Windows'
Require-Text '.github/workflows/release-desktop.yml' $desktopWorkflow 'mycomic-*-windows-setup.exe' 'desktop workflow must upload Windows installer assets'
Require-Text '.github/workflows/release-desktop.yml' $desktopWorkflow 'Publish mirror update manifest (Windows assets)' 'Windows release assets must merge into the update manifest'
Require-Text '.github/workflows/release-desktop.yml' $desktopWorkflow 'native/galgame_hook/tools/build_distribution.ps1 -RunTests' 'Windows releases must build the bundled offline galgame helper from the in-tree source'
Require-Text '.github/workflows/release-desktop.yml' $desktopWorkflow 'install_into_bundle.ps1 -BundleDirectory "$PWD\my_comic\build\windows\x64\runner\Release"' 'Windows release payload must unpack both helper architectures into the packaged Release bundle (BUG-1449)'

$multiplatformWorkflow = Read-RepoFile '.github/workflows/build-multiplatform.yml'
Require-Text '.github/workflows/build-multiplatform.yml' $multiplatformWorkflow 'native/galgame_hook/tools/build_distribution.ps1 -RunTests' 'Windows CI must exercise the same bundled helper build as release'
Require-Text '.github/workflows/build-multiplatform.yml' $multiplatformWorkflow 'install_into_bundle.ps1 -BundleDirectory "$PWD\my_comic\build\windows\x64\runner\Debug"' 'Windows debug bundle must exercise the same build-time helper unpack as release (BUG-1449)'

# BUG-1292: Magpie has no download path left, so the bundled slim archive is the
# ONLY way window upscaling can ever install.
$magpieBundleWorkflows = @{
  '.github/workflows/release-desktop.yml'     = @{ Content = $desktopWorkflow; Payload = 'Release\magpie_bundle' }
  '.github/workflows/build-multiplatform.yml' = @{ Content = $multiplatformWorkflow; Payload = 'Debug\magpie_bundle' }
}
foreach ($relativePath in $magpieBundleWorkflows.Keys) {
  $entry = $magpieBundleWorkflows[$relativePath]
  $content = $entry.Content
  Require-Text $relativePath $content 'tools/build_magpie_slim.ps1' 'Windows bundles must build the slim Magpie archive from the in-tree script (BUG-1217/BUG-1292)'
  Require-Text $relativePath $content $entry.Payload 'Windows bundle payload must contain magpie_bundle/ or window upscaling can never install (BUG-1292)'
  Require-Text $relativePath $content 'Magpie-hibiki-slim-x64.zip.sha256' 'the bundled Magpie archive must ship with its sha256 sidecar; the installer refuses an unverified package (BUG-1292)'
}

if ($failures.Count -gt 0) {
  Write-Error ("Release policy guard failed:`n- " + ($failures -join "`n- "))
  exit 1
}

Write-Host 'Release policy guard passed.'
