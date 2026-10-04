[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$projectRoot = [IO.Path]::GetFullPath((Split-Path -Parent $PSScriptRoot))
$gameRoot = Join-Path $projectRoot 'game'
$stageParent = Join-Path $projectRoot 'tmp\android-export-staging'
$stageName = 'android-debug-{0}-{1}' -f [DateTime]::UtcNow.ToString('yyyyMMddTHHmmssfffffffZ'), ([Guid]::NewGuid().ToString('N').Substring(0, 8))
$stageRoot = Join-Path $stageParent $stageName

function Assert-PlainDirectory([string]$Path) {
    $item = Get-Item -LiteralPath $Path -Force -ErrorAction Stop
    if (-not $item.PSIsContainer -or ($item.Attributes -band [IO.FileAttributes]::ReparsePoint)) {
        throw "Directory is missing or is a reparse point: $Path"
    }
}

function Assert-WithinProject([string]$Path) {
    $fullPath = [IO.Path]::GetFullPath($Path)
    $prefix = $projectRoot.TrimEnd([IO.Path]::DirectorySeparatorChar) + [IO.Path]::DirectorySeparatorChar
    if (-not $fullPath.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)) {
        throw "Path is outside the project workspace: $Path"
    }
}

function Assert-SafeFile([IO.FileInfo]$File, [string]$Kind) {
    if ($File.Attributes -band [IO.FileAttributes]::ReparsePoint) {
        throw "Linked files are not allowed in Android staging: $($File.FullName)"
    }
    $name = $File.Name
    if ($name -match '(?i)(^\.env(?:\.|$)|credential|secret|private.?key|api.?key|\.(?:key|pem|p12|pfx|jks|keystore|db|sqlite3?|csv|tsv|json|zip|bak|log)$)') {
        throw "Sensitive or data-like file is not allowed in Android staging: $($File.FullName)"
    }
    $pattern = switch ($Kind) {
        'scenes' { '\.(?:tscn|scn|tres|res|gdshader)(?:\.uid)?$' }
        'scripts' { '\.(?:gd|gdshader)(?:\.uid)?$' }
        'assets' { '\.(?:glb|gltf|png|jpe?g|webp|svg|ogg|wav|mp3|ttf|otf|tres|res)(?:\.import)?$' }
        default { throw "Unknown staging source kind: $Kind" }
    }
    if ($name -notmatch $pattern) {
        throw "File type is not on the Android resource allowlist: $($File.FullName)"
    }
}

function Get-SafeSourceFiles([string]$SourceRoot, [string]$Kind) {
    Assert-PlainDirectory $SourceRoot
    $pending = New-Object 'System.Collections.Generic.Stack[string]'
    $pending.Push($SourceRoot)
    while ($pending.Count -gt 0) {
        $directory = $pending.Pop()
        foreach ($item in Get-ChildItem -LiteralPath $directory -Force -ErrorAction Stop) {
            Assert-WithinProject $item.FullName
            if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) {
                throw "Linked source entry is not allowed in Android staging: $($item.FullName)"
            }
            if ($item.PSIsContainer) {
                if ($item.Name -match '(?i)^(?:\.git|\.godot|tests?|tmp|temp|logs?|user|__pycache__)$') {
                    throw "Data or test directory is not allowed in Android staging: $($item.FullName)"
                }
                $pending.Push($item.FullName)
            } else {
                Assert-SafeFile $item $Kind
                $item.FullName
            }
        }
    }
}

# Validate the entire source manifest before creating any output. In particular,
# user:// data, game/tests, game/tmp, environment files and credentials are never
# opened or copied by this script.
Assert-PlainDirectory $projectRoot
Assert-PlainDirectory $gameRoot
$projectFile = Join-Path $gameRoot 'project.godot'
$projectItem = Get-Item -LiteralPath $projectFile -Force -ErrorAction Stop
if ($projectItem.PSIsContainer -or ($projectItem.Attributes -band [IO.FileAttributes]::ReparsePoint)) {
    throw "project.godot must be a regular file: $projectFile"
}

$manifest = New-Object 'System.Collections.Generic.List[object]'
$manifest.Add([pscustomobject]@{ Source = $projectFile; Relative = 'project.godot'; Kind = 'project' })
foreach ($kind in @('scenes', 'scripts', 'assets')) {
    $sourceRoot = Join-Path $gameRoot $kind
    foreach ($source in Get-SafeSourceFiles $sourceRoot $kind) {
        $relative = $source.Substring($gameRoot.Length).TrimStart([IO.Path]::DirectorySeparatorChar)
        $manifest.Add([pscustomobject]@{ Source = $source; Relative = $relative; Kind = $kind })
    }
}

Assert-WithinProject $stageRoot
$tmpRoot = Join-Path $projectRoot 'tmp'
foreach ($existingParent in @($tmpRoot, $stageParent)) {
    if (Test-Path -LiteralPath $existingParent) { Assert-PlainDirectory $existingParent }
}
if (Test-Path -LiteralPath $stageRoot) {
    throw "Refusing to overwrite an existing Android staging directory: $stageRoot"
}
New-Item -ItemType Directory -Path $stageParent -Force | Out-Null
New-Item -ItemType Directory -Path $stageRoot -ErrorAction Stop | Out-Null

foreach ($entry in $manifest) {
    $destination = Join-Path $stageRoot $entry.Relative
    $destinationParent = Split-Path -Parent $destination
    if (-not (Test-Path -LiteralPath $destinationParent)) {
        New-Item -ItemType Directory -Path $destinationParent -Force | Out-Null
    }
    if (Test-Path -LiteralPath $destination) {
        throw "Refusing to overwrite a staged file: $destination"
    }
    Copy-Item -LiteralPath $entry.Source -Destination $destination -ErrorAction Stop
}

$stagedFiles = @(Get-ChildItem -LiteralPath $stageRoot -File -Recurse -Force -ErrorAction Stop)
if ($stagedFiles.Count -ne $manifest.Count) {
    throw "Staging self-check failed: expected $($manifest.Count) files, found $($stagedFiles.Count)"
}
foreach ($entry in $manifest) {
    $destination = Join-Path $stageRoot $entry.Relative
    if (-not (Test-Path -LiteralPath $destination -PathType Leaf)) {
        throw "Staging self-check failed: missing $($entry.Relative)"
    }
}

Write-Output "STAGING_PATH=$stageRoot"
Write-Output "STAGING_FILE_COUNT=$($stagedFiles.Count)"
foreach ($kind in @('project', 'scenes', 'scripts', 'assets')) {
    $count = @($manifest | Where-Object { $_.Kind -eq $kind }).Count
    Write-Output "STAGING_${kind}_COUNT=$count"
}
Write-Output 'STAGING_SELF_CHECK=PASS (source allowlist and output manifest)'
