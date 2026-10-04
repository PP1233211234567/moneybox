[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$GodotExe,
    [Parameter(Mandatory = $true)][string]$JdkRoot,
    [Parameter(Mandatory = $true)][string]$SdkRoot,
    [Parameter(Mandatory = $true)][string]$TemplatePath,
    [Parameter(Mandatory = $true)][string]$ApkPath,
    [Parameter(Mandatory = $true)][string]$PackPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$projectRoot = [IO.Path]::GetFullPath((Split-Path -Parent $PSScriptRoot))
$gameRoot = Join-Path $projectRoot 'game'

function Assert-WithinWorkspace([string]$Path) {
    $fullPath = [IO.Path]::GetFullPath($Path)
    $prefix = $projectRoot.TrimEnd([IO.Path]::DirectorySeparatorChar) + [IO.Path]::DirectorySeparatorChar
    if (-not $fullPath.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)) {
        throw "Output path is outside the project workspace: $Path"
    }
    $gamePrefix = $gameRoot.TrimEnd([IO.Path]::DirectorySeparatorChar) + [IO.Path]::DirectorySeparatorChar
    if ($fullPath.StartsWith($gamePrefix, [StringComparison]::OrdinalIgnoreCase)) {
        throw "Output path must not be inside the source game project: $Path"
    }
}

function Assert-PlainDirectory([string]$Path) {
    $item = Get-Item -LiteralPath $Path -Force -ErrorAction Stop
    if (-not $item.PSIsContainer -or ($item.Attributes -band [IO.FileAttributes]::ReparsePoint)) {
        throw "Directory is missing or is a reparse point: $Path"
    }
}

function Ensure-SafeOutputParent([string]$FilePath) {
    $parent = Split-Path -Parent $FilePath
    Assert-WithinWorkspace $parent
    $relative = $parent.Substring($projectRoot.Length).TrimStart([IO.Path]::DirectorySeparatorChar)
    $cursor = $projectRoot
    foreach ($segment in ($relative -split '[\\/]')) {
        if (-not $segment) { continue }
        $cursor = Join-Path $cursor $segment
        if (Test-Path -LiteralPath $cursor) {
            Assert-PlainDirectory $cursor
        } else {
            New-Item -ItemType Directory -Path $cursor -ErrorAction Stop | Out-Null
        }
    }
}

function Invoke-Godot([string]$Step, [string[]]$Arguments) {
    Write-Output "GODOT_STEP=$Step"
    $commandOutput = & $GodotExe @Arguments 2>&1
    $code = $LASTEXITCODE
    foreach ($line in @($commandOutput)) {
        $safeLine = [string]$line
        # Godot prints the apksigner command on successful debug exports.
        # Keep diagnostics while suppressing any keystore passwords in logs.
        $safeLine = [regex]::Replace($safeLine, '(?i)(--(?:ks|key)-pass\s+)\S+', '$1<REDACTED>')
        Write-Output $safeLine
    }
    Write-Output "GODOT_${Step}_EXIT_CODE=$code"
    if ($code -ne 0) { throw "Godot $Step failed with exit code $code" }
}

function Assert-NewArtifact([string]$Path, [string]$Extension) {
    if (-not $Path.EndsWith($Extension, [StringComparison]::OrdinalIgnoreCase)) {
        throw "Expected a $Extension output path: $Path"
    }
    Assert-WithinWorkspace $Path
    if (Test-Path -LiteralPath $Path) {
        throw "Refusing to overwrite existing output: $Path"
    }
}

function Assert-Artifact([string]$Path) {
    $item = Get-Item -LiteralPath $Path -ErrorAction Stop
    if ($item.PSIsContainer -or $item.Length -le 0) {
        throw "Export artifact is missing or empty: $Path"
    }
    return $item
}

function Assert-PackContents([string]$ZipPath) {
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $archive = [IO.Compression.ZipFile]::OpenRead($ZipPath)
    try {
        $fileCount = 0
        $forbiddenCount = 0
        foreach ($entry in $archive.Entries) {
            if (-not $entry.Name) { continue }
            $fileCount++
            $name = $entry.FullName.Replace('\', '/').TrimStart('/')
            if ($name.StartsWith('res://', [StringComparison]::OrdinalIgnoreCase)) {
                $name = $name.Substring(6)
            }
            if ($name -match '(?i)(?:^|/)\.\.(?:/|$)|(?:^|/)(?:tests?|tmp|temp|user)(?:/|$)|(?:^|/)\.env(?:\.|$)|(?:^|/)export_presets\.cfg$|(?:credential|secret|private.?key|api.?key)|\.(?:json|csv|tsv|db|sqlite3?|key|pem|p12|pfx|jks|keystore|bak|log)$') {
                $forbiddenCount++
            }
        }
        Write-Output "PACK_FILE_COUNT=$fileCount"
        Write-Output "PACK_FORBIDDEN_COUNT=$forbiddenCount"
        if ($fileCount -eq 0 -or $forbiddenCount -ne 0) {
            throw "Resource ZIP audit failed: files=$fileCount; forbidden=$forbiddenCount"
        }
    } finally {
        $archive.Dispose()
    }
}

function Enable-StagedAndroidTextures([string]$StageRoot) {
    $projectFile = Join-Path $StageRoot 'project.godot'
    $lines = New-Object 'System.Collections.Generic.List[string]'
    $lines.AddRange([string[]][IO.File]::ReadAllLines($projectFile))
    $sectionStart = -1
    for ($i = 0; $i -lt $lines.Count; $i++) {
        if ($lines[$i] -match '^\[rendering\]\s*$') { $sectionStart = $i; break }
    }
    if ($sectionStart -lt 0) {
        $lines.Add('')
        $lines.Add('[rendering]')
        $lines.Add('textures/vram_compression/import_etc2_astc=true')
    } else {
        $sectionEnd = $lines.Count
        for ($i = $sectionStart + 1; $i -lt $lines.Count; $i++) {
            if ($lines[$i] -match '^\[[^]]+\]\s*$') { $sectionEnd = $i; break }
        }
        $settingIndex = -1
        for ($i = $sectionStart + 1; $i -lt $sectionEnd; $i++) {
            if ($lines[$i] -match '^textures/vram_compression/import_etc2_astc\s*=') { $settingIndex = $i; break }
        }
        if ($settingIndex -ge 0) {
            $lines[$settingIndex] = 'textures/vram_compression/import_etc2_astc=true'
        } else {
            $lines.Insert($sectionEnd, 'textures/vram_compression/import_etc2_astc=true')
        }
    }
    [IO.File]::WriteAllLines($projectFile, $lines, (New-Object System.Text.UTF8Encoding($false)))
    Write-Output 'STAGING_ANDROID_VRAM_COMPRESSION=ETC2_ASTC'
}

Assert-PlainDirectory $projectRoot
$GodotExe = [IO.Path]::GetFullPath($GodotExe)
$JdkRoot = [IO.Path]::GetFullPath($JdkRoot)
$SdkRoot = [IO.Path]::GetFullPath($SdkRoot)
$TemplatePath = [IO.Path]::GetFullPath($TemplatePath)
$ApkPath = [IO.Path]::GetFullPath($ApkPath)
$PackPath = [IO.Path]::GetFullPath($PackPath)

if (-not (Test-Path -LiteralPath $GodotExe -PathType Leaf)) { throw "Godot executable is missing: $GodotExe" }
Assert-PlainDirectory $JdkRoot
Assert-PlainDirectory $SdkRoot
$javaExe = Join-Path $JdkRoot 'bin\java.exe'
if (-not (Test-Path -LiteralPath $javaExe -PathType Leaf)) { throw "JDK java.exe is missing: $javaExe" }
$adbExe = Join-Path $SdkRoot 'platform-tools\adb.exe'
if (-not (Test-Path -LiteralPath $adbExe -PathType Leaf)) { throw "Android SDK adb.exe is missing: $adbExe" }
$apksigner = Join-Path $SdkRoot 'build-tools\35.0.1\apksigner.bat'
if (-not (Test-Path -LiteralPath $apksigner -PathType Leaf)) { throw "Android Build-Tools 35.0.1 apksigner is missing: $apksigner" }
if (-not (Test-Path -LiteralPath (Join-Path $SdkRoot 'platforms\android-35') -PathType Container)) {
    throw "Android SDK Platform 35 is missing under $SdkRoot"
}
if (Test-Path -LiteralPath $TemplatePath -PathType Container) {
    $TemplatePath = Join-Path $TemplatePath 'android_debug.apk'
}
if (-not (Test-Path -LiteralPath $TemplatePath -PathType Leaf)) { throw "Godot Android debug template is missing: $TemplatePath" }

$versionOutput = @(& $GodotExe --version 2>&1)
$versionExit = $LASTEXITCODE
$godotVersion = (@($versionOutput) | Select-Object -First 1).ToString().Trim()
if ($versionExit -ne 0 -or -not $godotVersion.StartsWith('4.7.2.stable', [StringComparison]::OrdinalIgnoreCase)) {
    throw "Expected Godot 4.7.2 stable editor, found: $godotVersion"
}
Write-Output "GODOT_VERSION=$godotVersion"

# The official Android exporter reads these paths from Editor Settings. The
# portable editor is preconfigured outside this project; do not mutate it here.
$settingsPath = Join-Path (Split-Path -Parent $GodotExe) 'editor_data\editor_settings-4.7.tres'
if (-not (Test-Path -LiteralPath $settingsPath -PathType Leaf)) {
    throw "Portable Godot editor settings are missing: $settingsPath"
}
foreach ($setting in @(
    @{ Key = 'export/android/java_sdk_path'; Expected = $JdkRoot },
    @{ Key = 'export/android/android_sdk_path'; Expected = $SdkRoot }
)) {
    $match = Select-String -LiteralPath $settingsPath -Pattern ('^' + [regex]::Escape($setting.Key) + '\s*=\s*"([^"]+)"') | Select-Object -First 1
    if (-not $match) { throw "Godot Editor Settings lacks $($setting.Key)" }
    $configured = $match.Matches[0].Groups[1].Value.Replace('\\', '\')
    if (-not [IO.Path]::GetFullPath($configured).Equals($setting.Expected, [StringComparison]::OrdinalIgnoreCase)) {
        throw "Godot Editor Settings $($setting.Key) does not match the supplied path"
    }
}
Write-Output 'GODOT_EDITOR_ANDROID_PATHS=match'

Assert-NewArtifact $ApkPath '.apk'
Assert-NewArtifact $PackPath '.zip'
if ($ApkPath.Equals($PackPath, [StringComparison]::OrdinalIgnoreCase)) {
    throw 'APK and resource ZIP output paths must differ'
}
Ensure-SafeOutputParent $ApkPath
Ensure-SafeOutputParent $PackPath

$prepareOutput = @(& (Join-Path $PSScriptRoot 'prepare_android_debug.ps1'))
$prepareLine = $prepareOutput | Where-Object { $_ -is [string] -and $_.StartsWith('STAGING_PATH=') } | Select-Object -Last 1
if (-not $prepareLine) { throw 'Android staging preparation failed' }
$stageRoot = $prepareLine.Substring('STAGING_PATH='.Length)
Assert-WithinWorkspace $stageRoot
Assert-PlainDirectory $stageRoot
foreach ($line in $prepareOutput) { Write-Output $line }

$stagePrefix = $stageRoot.TrimEnd([IO.Path]::DirectorySeparatorChar) + [IO.Path]::DirectorySeparatorChar
foreach ($outputPath in @($ApkPath, $PackPath)) {
    if ($outputPath.StartsWith($stagePrefix, [StringComparison]::OrdinalIgnoreCase)) {
        throw "Export output must not be inside the staged Godot project: $outputPath"
    }
}

Enable-StagedAndroidTextures $stageRoot

$templateGodotPath = $TemplatePath.Replace('\', '/')
$preset = @"
[preset.0]
name="Android"
platform="Android"
runnable=true
advanced_options=false
dedicated_server=false
custom_features=""
export_filter="all_resources"
include_filter=""
exclude_filter=""
export_path=""
patches=PackedStringArray()
encryption_include_filters=""
encryption_exclude_filters=""
encrypt_pck=false
encrypt_directory=false

[preset.0.options]
custom_template/debug="$templateGodotPath"
custom_template/release=""
gradle_build/use_gradle_build=false
gradle_build/export_format=0
architectures/armeabi-v7a=true
architectures/arm64-v8a=true
architectures/x86=false
architectures/x86_64=false
package/unique_name="com.jindouguan.moneybox.debug"
package/name="金豆罐 Debug"
package/signed=true
keystore/debug=""
keystore/debug_user=""
keystore/debug_password=""
keystore/release=""
keystore/release_user=""
keystore/release_password=""
"@
$presetPath = Join-Path $stageRoot 'export_presets.cfg'
if (Test-Path -LiteralPath $presetPath) { throw "Refusing to overwrite staged preset: $presetPath" }
[IO.File]::WriteAllText($presetPath, $preset, (New-Object System.Text.UTF8Encoding($false)))

# Catch common embedded key formats in staged text resources without printing
# the matching content. The source tree is never scanned outside the staging
# allowlist, and this check does not claim to identify every possible secret.
$keySignature = '(?i)sk-[A-Za-z0-9_-]{20,}|-----BEGIN (?:RSA |EC |OPENSSH )?PRIVATE KEY-----|AIza[A-Za-z0-9_-]{20,}'
foreach ($textFile in Get-ChildItem -LiteralPath $stageRoot -File -Recurse -Force) {
    if ($textFile.Name -notmatch '(?i)\.(?:godot|gd|tscn|tres|import|cfg)$') { continue }
    if (Select-String -LiteralPath $textFile.FullName -Pattern $keySignature -Quiet) {
        throw "Potential embedded key signature in staged resource: $($textFile.FullName.Substring($stageRoot.Length))"
    }
}
Write-Output 'STAGING_SECRET_SIGNATURE_SCAN=PASS'

$oldJavaHome = $env:JAVA_HOME
$oldAndroidHome = $env:ANDROID_HOME
$oldAndroidSdkRoot = $env:ANDROID_SDK_ROOT
$env:JAVA_HOME = $JdkRoot
$env:ANDROID_HOME = $SdkRoot
$env:ANDROID_SDK_ROOT = $SdkRoot
try {
    Invoke-Godot 'IMPORT' @('--headless', '--editor', '--path', $stageRoot, '--import')

    $suffix = [Guid]::NewGuid().ToString('N').Substring(0, 8)
    $packTemporary = Join-Path (Split-Path -Parent $PackPath) (([IO.Path]::GetFileNameWithoutExtension($PackPath)) + ".partial-$suffix.zip")
    if (Test-Path -LiteralPath $packTemporary) { throw "Temporary ZIP already exists: $packTemporary" }
    Invoke-Godot 'PACK' @('--headless', '--path', $stageRoot, '--export-pack', 'Android', $packTemporary)
    $null = Assert-Artifact $packTemporary
    Assert-PackContents $packTemporary
    [IO.File]::Move($packTemporary, $PackPath)

    $apkTemporary = Join-Path (Split-Path -Parent $ApkPath) (([IO.Path]::GetFileNameWithoutExtension($ApkPath)) + ".partial-$suffix.apk")
    if (Test-Path -LiteralPath $apkTemporary) { throw "Temporary APK already exists: $apkTemporary" }
    Invoke-Godot 'APK' @('--headless', '--path', $stageRoot, '--export-debug', 'Android', $apkTemporary)
    $null = Assert-Artifact $apkTemporary
    $verifyOutput = & $apksigner verify $apkTemporary 2>&1
    $verifyExit = $LASTEXITCODE
    foreach ($line in @($verifyOutput)) { Write-Output $line }
    Write-Output "APKSIGNER_EXIT_CODE=$verifyExit"
    if ($verifyExit -ne 0) { throw "APK signature verification failed with exit code $verifyExit" }
    [IO.File]::Move($apkTemporary, $ApkPath)
} finally {
    $env:JAVA_HOME = $oldJavaHome
    $env:ANDROID_HOME = $oldAndroidHome
    $env:ANDROID_SDK_ROOT = $oldAndroidSdkRoot
}

foreach ($artifact in @(@{ Name = 'PACK'; Path = $PackPath }, @{ Name = 'APK'; Path = $ApkPath })) {
    $item = Assert-Artifact $artifact.Path
    $hash = (Get-FileHash -LiteralPath $artifact.Path -Algorithm SHA256).Hash
    Write-Output "$($artifact.Name)_PATH=$($artifact.Path)"
    Write-Output "$($artifact.Name)_BYTES=$($item.Length)"
    Write-Output "$($artifact.Name)_SHA256=$hash"
}
Write-Output 'ANDROID_DEBUG_EXPORT=PASS'
