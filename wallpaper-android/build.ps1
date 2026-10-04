param(
    [ValidateSet('check', 'build', 'install')]
    [string]$Action = 'build'
)

$ErrorActionPreference = 'Stop'
$projectDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$sdkCandidates = @(
    $env:ANDROID_HOME,
    $env:ANDROID_SDK_ROOT,
    (Join-Path $env:LOCALAPPDATA 'Android\Sdk')
) | Where-Object { $_ -and (Test-Path -LiteralPath $_ -PathType Container) }
$sdkPath = $sdkCandidates | Where-Object {
    Test-Path -LiteralPath (Join-Path $_ 'platforms\android-36\android.jar')
} | Select-Object -First 1
if (-not $sdkPath) { $sdkPath = $sdkCandidates | Select-Object -First 1 }
$java = Get-Command java -ErrorAction SilentlyContinue
$adb = Get-Command adb -ErrorAction SilentlyContinue
$wrapper = Join-Path $projectDir 'gradlew.bat'
$wrapperJar = Join-Path $projectDir 'gradle\wrapper\gradle-wrapper.jar'
$gradle = if ((Test-Path -LiteralPath $wrapper) -and
              (Test-Path -LiteralPath $wrapperJar)) {
    $wrapper
} else {
    (Get-Command gradle -ErrorAction SilentlyContinue).Source
}
$androidJar = if ($sdkPath) { Join-Path $sdkPath 'platforms\android-36\android.jar' } else { $null }

Write-Host "JDK java: $(if ($java) { $java.Source } else { 'MISSING' })"
Write-Host "Android SDK: $(if ($sdkPath) { $sdkPath } else { 'MISSING' })"
Write-Host "Android API 36: $(if ($androidJar -and (Test-Path -LiteralPath $androidJar)) { 'present' } else { 'MISSING' })"
Write-Host "Gradle executable (requires 8.13): $(if ($gradle) { $gradle } else { 'MISSING (wrapper JAR and system gradle absent)' })"
Write-Host "ADB: $(if ($adb) { $adb.Source } else { 'MISSING' })"

if ($Action -eq 'check') { return }
if (-not $java -or -not $sdkPath -or -not (Test-Path -LiteralPath $androidJar) -or -not $gradle) {
    throw 'Cannot build: install JDK 17, Android SDK API 36, and Gradle 8.13 or generate the pinned wrapper first.'
}

$env:ANDROID_HOME = $sdkPath
& $gradle -p $projectDir ':app:assembleDebug' '--no-daemon'
if ($LASTEXITCODE -ne 0) { throw "Gradle build failed with exit code $LASTEXITCODE" }

$apk = Join-Path $projectDir 'app\build\outputs\apk\debug\app-debug.apk'
if (-not (Test-Path -LiteralPath $apk)) { throw "Build succeeded but APK not found: $apk" }
Write-Host "APK: $apk"

if ($Action -eq 'install') {
    if (-not $adb) { throw 'Cannot install: adb is not available.' }
    & $adb.Source install -r $apk
    if ($LASTEXITCODE -ne 0) { throw "ADB install failed with exit code $LASTEXITCODE" }
    Write-Host 'Installed. Open the app and use the system wallpaper preview button.'
}
