# Checks every source file with clang (-fsyntax-only) against the iOS 9.3 SDK headers, the way the CI compiles it,
# without building anything: compile errors show up in seconds instead of a GitHub Actions round trip.
# Needs a clang (any recent LLVM for Windows), the unpacked iPhoneOS9.3.sdk from theos/sdks and the mbedTLS sources.
# Usage: .\tools\check-syntax.ps1 -Clang C:\llvm\bin\clang.exe -Sdk C:\sdks\iPhoneOS9.3.sdk -Mbedtls C:\mbedtls-3.6.7 [-Files src\UI\*.m]
param(
    [Parameter(Mandatory = $true)][string]$Clang,
    [Parameter(Mandatory = $true)][string]$Sdk,
    [Parameter(Mandatory = $true)][string]$Mbedtls,
    [string[]]$Files = @(),
    [switch]$Warnings
)
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
Set-Location $root

# the same config swap the CI does (vendor/mbedtls is not checked in)
$configDir = Join-Path $Mbedtls 'include\mbedtls'
if (-not (Test-Path (Join-Path $configDir 'mbedtls_config_default.h'))) {
    Rename-Item (Join-Path $configDir 'mbedtls_config.h') 'mbedtls_config_default.h'
}
Copy-Item (Join-Path $root 'vendor\mbedtls_config_ios6.h') (Join-Path $configDir 'mbedtls_config.h') -Force

$common = @(
    '-fsyntax-only', '-target', 'armv7-apple-ios6.0', '-isysroot', $Sdk, '-miphoneos-version-min=6.0',
    '-Wall', '-Wno-unused-variable', '-Wno-unused-function', '-Wno-unused-but-set-variable',
    '-Wno-deprecated-declarations', '-Wno-unknown-warning-option',
    '-Wno-nullability-completeness', '-Wno-nullability-completeness-on-arrays',
    '-Isrc', '-Isrc/Net', '-Isrc/Twitch', '-Isrc/UI', '-Isrc/Util', '-Ivendor',
    "-I$Mbedtls\include", "-I$Mbedtls\library"
)
$objc = @('-x', 'objective-c', '-fobjc-arc', '-Wunguarded-availability')

if (-not $Files.Count) {
    $Files = @(Get-ChildItem -Path (Join-Path $root 'src') -Recurse -Include *.m | ForEach-Object { $_.FullName })
    $Files += (Join-Path $root 'vendor\mbedtls_glue.c')
} else {
    $Files = @($Files | ForEach-Object { Get-ChildItem $_ } | ForEach-Object { $_.FullName })
}

$errors = 0
$warnings = 0
foreach ($file in $Files) {
    $rel = $file.Substring($root.Length + 1)
    $clangArgs = $common + $(if ($file -like '*.m') { $objc } else { @('-x', 'c') }) + @($file)
    $out = & $Clang @clangArgs 2>&1 | ForEach-Object { if ($_ -is [Management.Automation.ErrorRecord]) { $_.Exception.Message } else { [string]$_ } }
    $text = ($out -join "`n")
    $fileErrors = ([regex]::Matches($text, '(?m): (fatal )?error: ')).Count
    $fileWarnings = ([regex]::Matches($text, '(?m): warning: ')).Count
    $errors += $fileErrors
    $warnings += $fileWarnings
    if ($fileErrors -or ($Warnings -and $fileWarnings)) {
        Write-Host "== $rel ($fileErrors errors, $fileWarnings warnings)" -ForegroundColor $(if ($fileErrors) { 'Red' } else { 'Yellow' })
        # the message lines with their source line, without the caret art
        foreach ($line in ($text -split "`n")) {
            if ($line -match ': (fatal )?error: |: warning: |: note: ') { Write-Host ("  " + $line.Replace($root + '\', '')) }
        }
    } else {
        Write-Host "ok $rel ($fileWarnings warnings)"
    }
}
Write-Host ""
if ($errors) { Write-Host "$errors errors, $warnings warnings" -ForegroundColor Red; exit 1 }
Write-Host "No errors, $warnings warnings" -ForegroundColor Green
