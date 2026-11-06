[CmdletBinding()]
param(
    [string] $RuntimeSource = $env:MYCOMIC_MIHON_RUNTIME_SOURCE,
    [string] $NuGetPath = $env:MYCOMIC_NUGET,
    [switch] $SkipBuild,
    [switch] $NoLaunch
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

# Local Windows build-and-run flow for my-comic.
#
# `flutter build windows` never produces `mihon_bridge`. Fushi's Windows CI
# copies the pinned runtime into the Release directory after the build; this
# script is the local equivalent. The app itself stays fail-closed: it only
# launches the copy next to the executable, so this script must make that copy
# present before every launch.
#
# The runtime is taken verbatim from an existing official Fushi v3.0.0
# installation (or built with Fushi's own script on a cache miss). It is not
# rebuilt while the cache is valid, and the script never falls back to a
# system Java or another installed app.
#
# Deliberate duplication: the Flutter discovery and runtime staging/backup
# logic mirror tool/bootstrap.ps1 and tool/mihon/build_desktop_runtime.ps1.
# This script is the single Windows local entry point; keep the copies in sync
# or extract shared helpers if they start to diverge.

$RepositoryRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$FushiDir = Join-Path $RepositoryRoot 'fushi'
$ReleaseDir = Join-Path $FushiDir 'build\windows\x64\runner\Release'
$Exe = Join-Path $ReleaseDir 'fushi.exe'
$Stamp = Join-Path $FushiDir 'build\.last_built_commit'
$CacheDir = Join-Path $RepositoryRoot '.dart_tool\mihon_bridge'
$BundleDir = Join-Path $ReleaseDir 'mihon_bridge'

# Official Fushi v3.0.0 Bundled extension runtime. The vendored build is
# reproducible and produces the same jar, so this pins provenance even when the
# cache is seeded from a source build. See ADR-0009.
$OfficialRuntimeSha256 = '648886cac618a0119c9108573ba0d7bf09db420926e3044d76ec16ec7777e4df'

function Get-PinnedFlutterVersion {
    $fvmrc = Join-Path $FushiDir '.fvmrc'
    if (-not (Test-Path -LiteralPath $fvmrc -PathType Leaf)) {
        throw "Missing Flutter version pin: $fvmrc"
    }
    $json = Get-Content -LiteralPath $fvmrc -Raw | ConvertFrom-Json
    $version = [string]$json.flutter
    if ([string]::IsNullOrWhiteSpace($version)) {
        throw "$fvmrc does not contain a flutter version"
    }
    return $version
}

function Get-FlutterSdkVersion {
    param([string] $SdkRoot)
    $json = Join-Path $SdkRoot 'bin\cache\flutter.version.json'
    if (Test-Path -LiteralPath $json -PathType Leaf) {
        $text = Get-Content -LiteralPath $json -Raw
        $match = [regex]::Match($text, '"frameworkVersion"\s*:\s*"([^"]+)"')
        if ($match.Success) { return $match.Groups[1].Value.Trim() }
    }
    $legacy = Join-Path $SdkRoot 'version'
    if (Test-Path -LiteralPath $legacy -PathType Leaf) {
        return ([IO.File]::ReadAllText($legacy)).Trim()
    }
    return $null
}

function Get-FlutterExeInSdk {
    param([string] $SdkRoot)
    $exe = Join-Path $SdkRoot 'bin\flutter.bat'
    if (Test-Path -LiteralPath $exe -PathType Leaf) { return $exe }
    return $null
}

function Resolve-Flutter {
    if ($env:FUSHI_FLUTTER) {
        $configured = $env:FUSHI_FLUTTER
        if (Test-Path -LiteralPath $configured -PathType Container) {
            $configured = Join-Path $configured 'bin\flutter.bat'
        }
        if (-not (Test-Path -LiteralPath $configured -PathType Leaf)) {
            throw "FUSHI_FLUTTER does not point to flutter.bat: $($env:FUSHI_FLUTTER)"
        }
        return $configured
    }

    $version = Get-PinnedFlutterVersion
    $candidates = New-Object System.Collections.Generic.List[string]
    if ($env:FVM_CACHE_PATH) { $candidates.Add((Join-Path $env:FVM_CACHE_PATH "versions\$version")) }
    if ($env:FVM_HOME) { $candidates.Add((Join-Path $env:FVM_HOME "versions\$version")) }
    if ($env:LOCALAPPDATA) { $candidates.Add((Join-Path $env:LOCALAPPDATA "fvm\versions\$version")) }
    if ($HOME) {
        $candidates.Add((Join-Path $HOME "fvm\versions\$version"))
        $candidates.Add((Join-Path $HOME ".fvm\versions\$version"))
    }

    $bases = New-Object System.Collections.Generic.List[string]
    if ($HOME) { $bases.Add($HOME) }
    try {
        foreach ($drive in [IO.DriveInfo]::GetDrives()) {
            if ($drive.DriveType -eq [IO.DriveType]::Fixed) {
                $bases.Add($drive.RootDirectory.FullName)
            }
        }
    } catch { }
    foreach ($base in $bases) {
        $candidates.Add((Join-Path $base "flutter_sdk\flutter_$version"))
        $candidates.Add((Join-Path $base "flutter_$version"))
    }

    foreach ($sdk in $candidates) {
        if (-not (Test-Path -LiteralPath $sdk)) { continue }
        $reported = Get-FlutterSdkVersion -SdkRoot $sdk
        if ($reported -and $reported -ne $version) { continue }
        $exe = Get-FlutterExeInSdk -SdkRoot $sdk
        if ($exe) { return $exe }
    }

    $onPath = Get-Command flutter -CommandType Application -ErrorAction SilentlyContinue |
        Select-Object -First 1
    if ($onPath) {
        $sdk = Split-Path -Parent (Split-Path -Parent $onPath.Source)
        $reported = Get-FlutterSdkVersion -SdkRoot $sdk
        if ($reported -eq $version) { return $onPath.Source }
    }

    throw "Flutter $version (pinned by fushi/.fvmrc) was not found. Set FUSHI_FLUTTER to its flutter.bat."
}

function Get-GitHead {
    $head = (& git -C $RepositoryRoot rev-parse HEAD 2>$null | Out-String).Trim()
    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($head)) {
        throw "git rev-parse HEAD failed in $RepositoryRoot"
    }
    return $head
}

function Assert-TargetNotRunning {
    $target = [IO.Path]::GetFullPath($Exe)
    $running = Get-Process -Name 'fushi' -ErrorAction SilentlyContinue | Where-Object {
        try {
            $path = $_.Path
            return ($path -and ([IO.Path]::GetFullPath($path) -ieq $target))
        } catch {
            return $false
        }
    }
    if ($running) {
        throw "Close my-comic before building: $Exe is running."
    }
}

function Resolve-NuGet {
    $candidates = New-Object System.Collections.Generic.List[string]
    if ($NuGetPath) { $candidates.Add($NuGetPath) }
    if ($env:MYCOMIC_NUGET) { $candidates.Add($env:MYCOMIC_NUGET) }
    $candidates.Add((Join-Path $RepositoryRoot '.dart_tool\nuget\nuget.exe'))
    if ($env:ProgramFiles) { $candidates.Add((Join-Path $env:ProgramFiles 'NuGet\NuGet.exe')) }
    if (${env:ProgramFiles(x86)}) {
        $candidates.Add((Join-Path ${env:ProgramFiles(x86)} 'NuGet\NuGet.exe'))
    }
    if ($env:ChocolateyInstall) {
        $candidates.Add((Join-Path $env:ChocolateyInstall 'bin\nuget.exe'))
    }
    foreach ($candidate in $candidates) {
        if ([string]::IsNullOrWhiteSpace($candidate)) { continue }
        if (Test-Path -LiteralPath $candidate -PathType Leaf) { return $candidate }
        if (Test-Path -LiteralPath $candidate -PathType Container) {
            $exe = Join-Path $candidate 'nuget.exe'
            if (Test-Path -LiteralPath $exe -PathType Leaf) { return $exe }
        }
    }
    $onPath = Get-Command nuget -CommandType Application -ErrorAction SilentlyContinue |
        Select-Object -First 1
    if ($onPath) { return $onPath.Source }
    return $null
}

function Invoke-Flutter {
    param(
        [string] $Flutter,
        [string[]] $Arguments
    )
    Push-Location $FushiDir
    try {
        & $Flutter @Arguments
        if ($LASTEXITCODE -ne 0) {
            throw "flutter $($Arguments -join ' ') failed with exit code $LASTEXITCODE"
        }
    } finally {
        Pop-Location
    }
}

function Invoke-Dart {
    param(
        [string] $Flutter,
        [string[]] $Arguments
    )
    $dart = Join-Path (Split-Path -Parent $Flutter) 'dart.bat'
    if (-not (Test-Path -LiteralPath $dart -PathType Leaf)) {
        throw "dart.bat was not found next to $Flutter"
    }
    Push-Location $FushiDir
    try {
        & $dart @Arguments
        if ($LASTEXITCODE -ne 0) {
            throw "dart $($Arguments -join ' ') failed with exit code $LASTEXITCODE"
        }
    } finally {
        Pop-Location
    }
}

function Test-RuntimeLayout {
    param([string] $Path)
    if ([string]::IsNullOrWhiteSpace($Path)) { return $false }
    if (-not (Test-Path -LiteralPath (Join-Path $Path 'm-extension-server.jar') -PathType Leaf)) { return $false }
    if (-not (Test-Path -LiteralPath (Join-Path $Path 'runtime\bin\java.exe') -PathType Leaf)) { return $false }
    if (-not (Test-Path -LiteralPath (Join-Path $Path 'checksums.json') -PathType Leaf)) { return $false }
    return $true
}

function Test-RuntimeDirectory {
    param([string] $Path)
    if (-not (Test-RuntimeLayout $Path)) { return $false }
    $jar = Join-Path $Path 'm-extension-server.jar'
    $actual = (Get-FileHash -LiteralPath $jar -Algorithm SHA256).Hash.ToLowerInvariant()
    return ($actual -eq $OfficialRuntimeSha256)
}

function Assert-RuntimeChecksum {
    param([string] $Path)
    $checksumsPath = Join-Path $Path 'checksums.json'
    $checksums = Get-Content -LiteralPath $checksumsPath -Raw | ConvertFrom-Json
    $expected = [string]$checksums.mExtensionServer.sha256
    if ([string]::IsNullOrWhiteSpace($expected)) {
        throw "$checksumsPath does not contain mExtensionServer.sha256"
    }
    if ($expected.ToLowerInvariant() -ne $OfficialRuntimeSha256) {
        throw "Runtime manifest does not describe the official Fushi v3.0.0 runtime: expected $OfficialRuntimeSha256, got $($expected.ToLowerInvariant())"
    }
    $jar = Join-Path $Path 'm-extension-server.jar'
    $actual = (Get-FileHash -LiteralPath $jar -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($actual -ne $OfficialRuntimeSha256) {
        throw "Runtime jar checksum mismatch: expected $OfficialRuntimeSha256, got $actual"
    }
}

function Install-RuntimeBundle {
    $staging = "$BundleDir.staging-$([Guid]::NewGuid().ToString('N'))"
    $backup = $null
    try {
        # 校验**源缓存**（含 jar 哈希），不要在 staging 上做哈希：Get-FileHash
        # 读取会触发 Windows Defender / 搜索索引对新拷贝 jar 的扫描，随后重命名
        # staging 目录会因文件句柄被占用而报「访问被拒绝」。staging 只查结构，
        # 然后立刻换入；换入成功后再对正式目录做哈希校验。
        if (-not (Test-RuntimeDirectory $CacheDir)) {
            throw "Runtime cache is incomplete: $CacheDir"
        }
        Assert-RuntimeChecksum -Path $CacheDir
        [IO.Directory]::CreateDirectory((Split-Path -Parent $BundleDir)) | Out-Null
        Copy-Item -LiteralPath $CacheDir -Destination $staging -Recurse -Force
        if (-not (Test-RuntimeLayout $staging)) {
            throw "Staged runtime is incomplete: $staging"
        }
        if (Test-Path -LiteralPath $BundleDir) {
            $backup = "$BundleDir.backup-$([Guid]::NewGuid().ToString('N'))"
            Move-Item -LiteralPath $BundleDir -Destination $backup
        }
        try {
            # 扫描器/索引器可能短暂持有 staging 里的文件；立即重试几次，而不是
            # 第一次 Rename 失败就把整个启动流程判死。
            $moved = $false
            for ($attempt = 0; $attempt -lt 5 -and -not $moved; $attempt++) {
                try {
                    Move-Item -LiteralPath $staging -Destination $BundleDir -ErrorAction Stop
                    $moved = $true
                } catch {
                    if ($attempt -ge 4) { throw }
                    Start-Sleep -Milliseconds 400
                }
            }
            Assert-RuntimeChecksum -Path $BundleDir
            if ($backup) {
                Remove-Item -LiteralPath $backup -Recurse -Force
                $backup = $null
            }
        } catch {
            if ($backup -and -not (Test-Path -LiteralPath $BundleDir)) {
                Move-Item -LiteralPath $backup -Destination $BundleDir
                $backup = $null
            }
            throw
        }
    } finally {
        if ($backup -and (Test-Path -LiteralPath $backup)) {
            Remove-Item -LiteralPath $backup -Recurse -Force -ErrorAction SilentlyContinue
        }
        if (Test-Path -LiteralPath $staging) {
            Remove-Item -LiteralPath $staging -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}

Assert-TargetNotRunning

$head = Get-GitHead
$needsBuild = $true
if (Test-Path -LiteralPath $Exe -PathType Leaf) {
    if (Test-Path -LiteralPath $Stamp -PathType Leaf) {
        $built = ([IO.File]::ReadAllText($Stamp)).Trim()
        if ($built -eq $head) { $needsBuild = $false }
    }
}
if ($SkipBuild) { $needsBuild = $false }

if ($needsBuild) {
    $nuget = Resolve-NuGet
    if (-not $nuget) {
        throw "NuGet.exe is required for the Windows WebView2/WIL dependencies. Put nuget.exe in .dart_tool\nuget\ or set MYCOMIC_NUGET to its path."
    }
    $nugetDirectory = Split-Path -Parent $nuget
    $pathParts = $env:PATH -split ';'
    if ($pathParts -notcontains $nugetDirectory) {
        $env:PATH = "$nugetDirectory;$env:PATH"
    }

    $flutter = Resolve-Flutter
    $workspaceLock = Join-Path $RepositoryRoot 'pubspec.lock'
    $localLockDirectory = Join-Path $RepositoryRoot '.dart_tool\my-comic'
    $localLock = Join-Path $localLockDirectory 'pubspec.lock'
    $pendingLocalLock = Join-Path $localLockDirectory 'pubspec.lock.pending'
    if (Test-Path -LiteralPath $pendingLocalLock) {
        Remove-Item -LiteralPath $pendingLocalLock -Force
    }
    $originalLock = $null
    if (Test-Path -LiteralPath $workspaceLock -PathType Leaf) {
        $originalLock = [IO.File]::ReadAllBytes($workspaceLock)
    }
    $saveResolvedLock = $false
    try {
        if (Test-Path -LiteralPath $localLock -PathType Leaf) {
            Copy-Item -LiteralPath $localLock -Destination $workspaceLock -Force
            Write-Host "[my-comic] flutter pub get --enforce-lockfile (local lock)"
            try {
                Invoke-Flutter -Flutter $flutter -Arguments @('pub', 'get', '--enforce-lockfile')
            } catch {
                Write-Host "[my-comic] local lock no longer satisfies pubspec; resolving"
                Invoke-Flutter -Flutter $flutter -Arguments @('pub', 'get')
                $saveResolvedLock = $true
            }
        } else {
            Write-Host "[my-comic] flutter pub get"
            Invoke-Flutter -Flutter $flutter -Arguments @('pub', 'get')
            $saveResolvedLock = $true
        }
        if ($saveResolvedLock) {
            [IO.Directory]::CreateDirectory($localLockDirectory) | Out-Null
            Copy-Item -LiteralPath $workspaceLock -Destination $pendingLocalLock -Force
        }
    } finally {
        if ($null -ne $originalLock) {
            [IO.File]::WriteAllBytes($workspaceLock, $originalLock)
        }
    }

    $generatedStrings = Join-Path $FushiDir 'lib\i18n\strings.g.dart'
    $needsSlang = -not (Test-Path -LiteralPath $generatedStrings -PathType Leaf)
    if (-not $needsSlang) {
        $generatedAt = (Get-Item -LiteralPath $generatedStrings).LastWriteTimeUtc
        $needsSlang = @(
            Get-ChildItem -LiteralPath (Split-Path -Parent $generatedStrings) -Filter '*.i18n.json' -File |
                Where-Object { $_.LastWriteTimeUtc -gt $generatedAt }
        ).Count -gt 0
    }
    if ($needsSlang) {
        Write-Host "[my-comic] dart run slang"
        Invoke-Dart -Flutter $flutter -Arguments @('run', 'slang')
        Write-Host "[my-comic] dart format lib/i18n/strings.g.dart"
        Invoke-Dart -Flutter $flutter -Arguments @('format', 'lib/i18n/strings.g.dart')
    }

    Write-Host "[my-comic] flutter build windows --release"
    Invoke-Flutter -Flutter $flutter -Arguments @('build', 'windows', '--release', '--no-pub')
    if ($saveResolvedLock -and (Test-Path -LiteralPath $pendingLocalLock -PathType Leaf)) {
        [IO.Directory]::CreateDirectory($localLockDirectory) | Out-Null
        Move-Item -LiteralPath $pendingLocalLock -Destination $localLock -Force
    }
    [IO.Directory]::CreateDirectory((Split-Path -Parent $Stamp)) | Out-Null
    [IO.File]::WriteAllText($Stamp, $head, (New-Object Text.UTF8Encoding($false)))
} else {
    Write-Host "[my-comic] build is current ($($head.Substring(0, [Math]::Min(12, $head.Length))))"
}

if (-not (Test-Path -LiteralPath $Exe -PathType Leaf)) {
    throw "Build did not produce $Exe"
}

if (-not (Test-RuntimeDirectory $CacheDir)) {
    if ($RuntimeSource) {
        if (-not (Test-RuntimeDirectory $RuntimeSource)) {
            throw "Runtime source is not a complete official runtime (from -RuntimeSource or MYCOMIC_MIHON_RUNTIME_SOURCE): $RuntimeSource"
        }
        Write-Host "[my-comic] seeding runtime cache from $RuntimeSource"
        if (Test-Path -LiteralPath $CacheDir) {
            Remove-Item -LiteralPath $CacheDir -Recurse -Force
        }
        [IO.Directory]::CreateDirectory((Split-Path -Parent $CacheDir)) | Out-Null
        Copy-Item -LiteralPath $RuntimeSource -Destination $CacheDir -Recurse -Force
    } else {
        $builder = Join-Path $RepositoryRoot 'tool\mihon\build_desktop_runtime.ps1'
        if (-not (Test-Path -LiteralPath $builder -PathType Leaf)) {
            throw "Runtime cache is missing and $builder does not exist. Set MYCOMIC_MIHON_RUNTIME_SOURCE to an existing runtime."
        }
        Write-Host "[my-comic] building Mihon desktop runtime (cache miss)"
        & $builder -OutputDirectory $CacheDir
        if ($LASTEXITCODE -ne 0) {
            throw "Mihon desktop runtime build failed with exit code $LASTEXITCODE"
        }
    }
}
if (-not (Test-RuntimeDirectory $CacheDir)) {
    throw "Runtime cache is incomplete: $CacheDir"
}

if (Test-RuntimeDirectory $BundleDir) {
    Write-Host "[my-comic] runtime bundle is current"
} else {
    Write-Host "[my-comic] bundling runtime into $BundleDir"
    Install-RuntimeBundle
}

if (-not $NoLaunch) {
    Write-Host "[my-comic] launching $Exe"
    Start-Process -FilePath $Exe -WorkingDirectory $ReleaseDir
}
