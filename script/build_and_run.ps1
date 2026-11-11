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
# script is the local equivalent.
#
# The app itself stays fail-closed: it only launches the copy next to the
# executable, so this script must make that copy present before every launch.
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
$LogPath = Join-Path $RepositoryRoot '启动日志.txt'

function Write-LauncherLog {
    param([string] $Message)
    try {
        $line = "[{0}] {1}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Message
        Add-Content -LiteralPath $LogPath -Value $line -Encoding UTF8
    } catch {
        # 日志写失败不能影响启动。
    }
}

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

function Get-BuildStamp {
    $parts = New-Object System.Collections.Generic.List[string]
    foreach ($path in @('fushi', 'packages', 'pubspec.yaml', 'pubspec.lock')) {
        $value = (& git -C $RepositoryRoot rev-parse "HEAD:$path" 2>$null | Out-String).Trim()
        if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($value)) {
            throw "git rev-parse HEAD:$path failed in $RepositoryRoot"
        }
        $parts.Add($value)
    }
    $bytes = [Text.Encoding]::UTF8.GetBytes(($parts -join "`n"))
    $sha = [Security.Cryptography.SHA256]::Create().ComputeHash($bytes)
    return (($sha | ForEach-Object { $_.ToString('x2') }) -join '')
}

function Get-RunningTargetProcess {
    $target = [IO.Path]::GetFullPath($Exe)
    $processes = @(Get-Process -Name 'fushi' -ErrorAction SilentlyContinue)
    foreach ($process in $processes) {
        try {
            $path = $process.Path
            if ($path -and ([IO.Path]::GetFullPath($path) -ieq $target)) {
                return $process
            }
        } catch {
            # 路径不可读：继续检查下一个进程。
        }
    }
    # 路径不可读时无法确认是否为目标 exe；按“可能正在运行”处理，避免构建时文件锁失败。
    foreach ($process in $processes) {
        try {
            if ([string]::IsNullOrWhiteSpace($process.Path)) {
                return $process
            }
        } catch {
            return $process
        }
    }
    return $null
}

function Show-LaunchedWindow {
    param([System.Diagnostics.Process] $Process)
    # 首次启动要先等 Flutter/WebView 把主窗口建出来，否则用户会以为没启动。
    $deadline = [DateTime]::UtcNow.AddSeconds(30)
    while ([DateTime]::UtcNow -lt $deadline) {
        $Process.Refresh()
        if ($Process.HasExited) { return $false }
        if ($Process.MainWindowHandle -ne 0) { break }
        Start-Sleep -Milliseconds 300
    }
    if ($Process.HasExited) { return $false }
    try {
        $null = (New-Object -ComObject WScript.Shell).AppActivate($Process.Id)
    } catch {
        # 窗口还在初始化时 AppActivate 可能失败；应用本身仍在运行。
    }
    return $true
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
    # Windows PowerShell 5.1 turns a native command's stderr into a
    # NativeCommandError when ErrorActionPreference is Stop. Flutter writes
    # normal notices (e.g. the storage mirror announcement) to stderr, so keep
    # this invocation non-terminating and rely on $LASTEXITCODE instead.
    $previousErrorAction = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        & $Flutter @Arguments 2>&1 | ForEach-Object {
            Write-Host $_
            try { Add-Content -LiteralPath $LogPath -Value $_ -Encoding UTF8 } catch { }
        }
        if ($LASTEXITCODE -ne 0) {
            throw "flutter $($Arguments -join ' ') failed with exit code $LASTEXITCODE"
        }
    } finally {
        $ErrorActionPreference = $previousErrorAction
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
    # See Invoke-Flutter: keep native stderr from becoming a terminating error.
    $previousErrorAction = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        & $dart @Arguments 2>&1 | ForEach-Object {
            Write-Host $_
            try { Add-Content -LiteralPath $LogPath -Value $_ -Encoding UTF8 } catch { }
        }
        if ($LASTEXITCODE -ne 0) {
            throw "dart $($Arguments -join ' ') failed with exit code $LASTEXITCODE"
        }
    } finally {
        $ErrorActionPreference = $previousErrorAction
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

$running = Get-RunningTargetProcess
if ($running) {
    if ($NoLaunch) {
        Write-LauncherLog "refusing to build: fushi is running (PID $($running.Id))"
        throw "Close my-comic before building: $Exe is running."
    }
    $activated = $false
    try {
        $activated = [bool](New-Object -ComObject WScript.Shell).AppActivate($running.Id)
    } catch {
        $activated = $false
    }
    if ($activated) {
        Write-Host "[my-comic] already running; brought it to the front."
        Write-LauncherLog "already running (PID $($running.Id)); activated"
        exit 0
    }
    Write-Host "[my-comic] already running (PID $($running.Id)), but its window could not be activated."
    Write-Host "[my-comic] Close my-comic completely, then run this launcher again."
    Write-LauncherLog "already running (PID $($running.Id)); activation failed"
    exit 1
}

$head = Get-GitHead
$buildStamp = Get-BuildStamp
Write-LauncherLog "start; head=$head; buildStamp=$buildStamp"
$needsBuild = $true
if (Test-Path -LiteralPath $Exe -PathType Leaf) {
    if (Test-Path -LiteralPath $Stamp -PathType Leaf) {
        $built = ([IO.File]::ReadAllText($Stamp)).Trim()
        if ($built -eq $buildStamp) { $needsBuild = $false }
    }
}
if ($SkipBuild) { $needsBuild = $false }

if ($needsBuild) {
    $shortHead = $head.Substring(0, [Math]::Min(12, $head.Length))
    Write-Host "[my-comic] build required for $shortHead; this can take 2-4 minutes..."
    Write-LauncherLog "build required; head=$head"
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

    # strings.g.dart is gitignored, so every build must generate it from the
    # current i18n sources. The old mtime check missed *deleted* translation
    # files (deleting an input does not touch the remaining files' mtimes),
    # which could leave a stale file with locales that no longer ship. ticket 06
    # makes generation unconditional: ~1s, and the build output always matches
    # the checked-in .i18n.json set.
    $generatedStrings = Join-Path $FushiDir 'lib\i18n\strings.g.dart'
    Write-Host "[my-comic] dart run slang"
    Invoke-Dart -Flutter $flutter -Arguments @('run', 'slang')
    if (-not (Test-Path -LiteralPath $generatedStrings -PathType Leaf)) {
        throw "dart run slang did not produce $generatedStrings"
    }
    Write-Host "[my-comic] dart format lib/i18n/strings.g.dart"
    Invoke-Dart -Flutter $flutter -Arguments @('format', 'lib/i18n/strings.g.dart')

    Write-Host "[my-comic] flutter build windows --release"
    Invoke-Flutter -Flutter $flutter -Arguments @('build', 'windows', '--release', '--no-pub')
    if ($saveResolvedLock -and (Test-Path -LiteralPath $pendingLocalLock -PathType Leaf)) {
        [IO.Directory]::CreateDirectory($localLockDirectory) | Out-Null
        Move-Item -LiteralPath $pendingLocalLock -Destination $localLock -Force
    }
    [IO.Directory]::CreateDirectory((Split-Path -Parent $Stamp)) | Out-Null
    [IO.File]::WriteAllText($Stamp, $buildStamp, (New-Object Text.UTF8Encoding($false)))
    Write-LauncherLog "build succeeded; stamp=$buildStamp"
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
    Write-LauncherLog "runtime bundle current"
} else {
    Write-Host "[my-comic] bundling runtime into $BundleDir"
    Write-LauncherLog "bundling runtime"
    Install-RuntimeBundle
    Write-LauncherLog "runtime bundled"
}

if (-not $NoLaunch) {
    Write-Host "[my-comic] launching $Exe"
    Write-LauncherLog "launching $Exe"
    $launched = Start-Process -FilePath $Exe -WorkingDirectory $ReleaseDir -PassThru
    if (-not (Show-LaunchedWindow -Process $launched)) {
        $launched.Refresh()
        $code = $launched.ExitCode
        Write-LauncherLog "app exited during startup; exitCode=$code"
        throw "my-comic exited during startup (exit code $code). See $LogPath for details."
    }
    Write-LauncherLog "app launched; PID=$($launched.Id)"
}
