param(
    [ValidateSet('core', 'all')]
    [string]$Scope = 'all'
)

$ErrorActionPreference = 'Stop'
$projectRoot = Split-Path -Parent $PSScriptRoot
$gameRoot = Join-Path $projectRoot 'game'
$logDirectory = Join-Path $projectRoot 'tests\logs'
New-Item -ItemType Directory -Path $logDirectory -Force | Out-Null

$godotCandidates = @(
    $env:GODOT_EXE,
    'D:\Apps\Godot\Godot-4.7.2\Godot_v4.7.2-stable_win64_console.exe'
) | Where-Object { $_ -and (Test-Path -LiteralPath $_ -PathType Leaf) }
$godot = $godotCandidates | Select-Object -First 1
if (-not $godot) {
    $command = Get-Command godot -ErrorAction SilentlyContinue
    if ($command) { $godot = $command.Source }
}
if (-not $godot) { throw 'Godot 4 console executable not found; set GODOT_EXE.' }

$tests = @(
    'tests/data/test_decimal.gd',
    'tests/data/test_ledger.gd',
    'tests/data/test_store.gd',
    'tests/data/test_store_fault_matrix.gd',
    'tests/data/test_demo_flow.gd',
    'tests/data/test_personal_flow.gd',
    'tests/data/test_display_snapshot.gd',
    'game/tests/domain/run_domain_tests.gd'
)
if ($Scope -eq 'all') {
    $tests += @(
        'game/scripts/visual/jar_smoke_test.gd',
        'game/scripts/visual/gold_asset_smoke_test.gd',
        'game/tests/visual/run_capacity_smoke.gd',
        'game/tests/visual/run_jar_shake_regression.gd',
        'game/tests/integration/run_demo_scene.gd',
        'game/tests/integration/run_personal_scene.gd',
        'game/tests/integration/run_personal_asset_entry_scene.gd',
        'game/tests/integration/run_personal_manual_revaluation_scene.gd',
        'game/tests/visual/inspect_personal_layout.gd',
        'game/tests/integration/run_personal_trade_draft_scene.gd',
        'game/tests/integration/run_personal_csv_import_scene.gd',
        'game/tests/integration/run_personal_csv_export_scene.gd',
        'game/tests/integration/run_personal_bean_organizer_scene.gd',
        'game/tests/integration/run_personal_backup_restore_scene.gd',
		'game/tests/integration/run_personal_reconciliation_scene.gd',
		'game/tests/integration/run_personal_ledger_history_scene.gd',
        'game/tests/ui/run_personal_overview_tests.gd',
        'game/tests/domain/run_personal_bean_organizer_tests.gd',
        'game/tests/reconciliation/run_reconciliation_tests.gd',
        'game/tests/trade/run_trade_tests.gd',
        'game/tests/trade/run_personal_trade_tests.gd',
        'game/tests/backup/run_backup_tests.gd',
        'game/tests/quotes/run_quote_tests.gd',
        'game/tests/quotes/run_quote_store_tests.gd',
        'game/tests/quotes/run_personal_gold_tests.gd',
        'game/tests/quotes/run_personal_manual_revaluation_tests.gd',
        'game/tests/data/run_personal_asset_flow_tests.gd',
        'game/tests/data/run_restricted_asset_tests.gd',
        'game/tests/data/run_other_asset_tests.gd',
        'game/tests/import/run_import_tests.gd',
        'game/tests/import/run_personal_import_tests.gd',
        'game/tests/export/run_ledger_csv_export_tests.gd',
        'game/tests/ecology/run_ecology_tests.gd',
        'game/tests/ecology/run_ecology_store_tests.gd',
        'game/tests/analytics/run_analytics_tests.gd',
        'game/tests/analytics/run_historical_valuation_tests.gd',
        'game/tests/fees/run_fee_tests.gd',
        'game/tests/tax/run_tax_tests.gd'
    )
}

$failed = @()
foreach ($relative in $tests) {
    $script = Join-Path $projectRoot $relative
    if (-not (Test-Path -LiteralPath $script -PathType Leaf)) {
        Write-Host "MISSING $relative"
        $failed += $relative
        continue
    }
    $log = Join-Path $logDirectory (($relative -replace '[\\/]', '-') + '.log')
    $testOutput = & $godot --headless --path $gameRoot --log-file $log --script $script 2>&1
    $testExitCode = $LASTEXITCODE
    foreach ($line in $testOutput) { Write-Host $line }
    $testText = @($testOutput) -join [Environment]::NewLine
    $scriptError = $testText -match '(?im)(^\s*SCRIPT ERROR:|^\s*ERROR: Failed to load script|^\s*ERROR: Can.t load script|(?:^|[_\s])FAIL(?:[:\s]|$))'
    $successMarker = $testText -match '(?i)(\bpass(?:ed)?\b|_pass\b|\b0 failures\b)'
    if ($testExitCode -eq 0 -and -not $scriptError -and $successMarker) {
        Write-Host "PASS $relative"
    } else {
        Write-Host "FAIL $relative (exit $testExitCode; scriptError=$scriptError; successMarker=$successMarker)"
        $failed += $relative
    }
}

if ($Scope -eq 'all') {
    $python = Get-Command python -ErrorAction SilentlyContinue
    if (-not $python) {
        Write-Host 'MISSING Python 3 for the local B0 HTTP tests'
        $failed += 'backend Python 3'
    } else {
        Push-Location $projectRoot
        try {
            & $python.Source -m unittest backend.test_dev_server -v
            if ($LASTEXITCODE -eq 0) {
                Write-Host 'PASS backend.test_dev_server'
            } else {
                Write-Host "FAIL backend.test_dev_server (exit $LASTEXITCODE)"
                $failed += 'backend.test_dev_server'
            }
        } finally {
            Pop-Location
        }
    }
    & (Join-Path $projectRoot 'wallpaper-android\build.ps1') -Action check
    Write-Host 'Android check reports installed tools only; it does not build an APK or verify a device.'
}

if ($failed.Count -gt 0) {
    throw "Verification failed or missing: $($failed -join ', ')"
}
Write-Host "Godot verification passed: $($tests.Count) scripts. Device and Android build remain separate gates."
