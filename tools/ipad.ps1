# Helpers for talking to the jailbroken iPad over SSH (dot-source this file).
#   . .\tools\ipad.ps1
#   Invoke-IPad 'uname -a'
#   Install-IPadPackage -IpaPath .\packages\GFN6-0.1.0.ipa -DebPath .\packages\com.samcejko.GFN6_0.1.0_iphoneos-arm.deb
#   Get-IPadCrashLogs
#   Get-IPadSyslog

$script:IPadKey = Join-Path $env:USERPROFILE '.ssh\ipad_ios6'
$script:IPadDefaultHost = '192.168.137.17'
$script:IPadLocalCfg = Join-Path $PSScriptRoot 'local.json'
if (Test-Path $script:IPadLocalCfg) {
    try {
        $c = Get-Content $script:IPadLocalCfg -Raw | ConvertFrom-Json
        if ($c.ipad) { $script:IPadDefaultHost = $c.ipad }
    } catch {}
}

function Get-IPadSshArgs {
    # (keepalives end a session whose Wi-Fi link died instead of waiting for ever)
    @('-i', $script:IPadKey, '-oHostKeyAlgorithms=+ssh-rsa', '-oStrictHostKeyChecking=accept-new', '-oConnectTimeout=10', '-oBatchMode=yes', '-oLogLevel=ERROR',
      '-oServerAliveInterval=5', '-oServerAliveCountMax=4')
}

# Runs a command on the iPad and returns stdout+stderr as plain strings (never throws on stderr output).
function Invoke-IPad {
    param([Parameter(Mandatory = $true)][string]$Command, [string]$IPadHost = $script:IPadDefaultHost)
    $ErrorActionPreference = 'Continue'   # function-local: native stderr must not become a terminating error
    $sshArgs = Get-IPadSshArgs
    & ssh.exe @sshArgs "root@$IPadHost" $Command 2>&1 |
        ForEach-Object { if ($_ -is [Management.Automation.ErrorRecord]) { $_.Exception.Message } else { $_ } }
}

function Copy-ToIPad {
    param([Parameter(Mandatory = $true)][string]$LocalPath, [Parameter(Mandatory = $true)][string]$RemotePath, [string]$IPadHost = $script:IPadDefaultHost)
    $ErrorActionPreference = 'Continue'
    $sshArgs = Get-IPadSshArgs
    & scp.exe -O @sshArgs $LocalPath "root@${IPadHost}:$RemotePath" 2>&1 |
        ForEach-Object { if ($_ -is [Management.Automation.ErrorRecord]) { $_.Exception.Message } else { $_ } }
    if ($LASTEXITCODE -ne 0) { throw "scp failed for $LocalPath" }
}

function Copy-FromIPad {
    param([Parameter(Mandatory = $true)][string]$RemotePath, [Parameter(Mandatory = $true)][string]$LocalPath, [string]$IPadHost = $script:IPadDefaultHost)
    $ErrorActionPreference = 'Continue'
    $sshArgs = Get-IPadSshArgs
    & scp.exe -O @sshArgs -r "root@${IPadHost}:$RemotePath" $LocalPath 2>&1 |
        ForEach-Object { if ($_ -is [Management.Automation.ErrorRecord]) { $_.Exception.Message } else { $_ } }
    if ($LASTEXITCODE -ne 0) { throw "scp failed for $RemotePath" }
}

function Install-IPadPackage {
    # GFN6 needs the DEB (install into /Applications) so the hardware video decoder is allowed by the sandbox;
    # the container IPA install is denied iokit-open AppleVXD390UserClient and shows a black screen. Pass -DebPath.
    # Giving only -IpaPath still works but video will not decode - a warning is printed.
    param([string]$IpaPath, [string]$DebPath, [string]$IPadHost = $script:IPadDefaultHost)
    $installed = $false
    Invoke-IPad -IPadHost $IPadHost -Command 'killall GFN6 2>/dev/null; echo stopped' | Out-Null
    # Prefer the DEB. When given a run folder's IPA, use the DEB sitting next to it.
    if (-not $DebPath -and $IpaPath) {
        $sibling = Join-Path (Split-Path $IpaPath) 'com.samcejko.gfn6_*.deb'
        $found = Get-ChildItem $sibling -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($found) { $DebPath = $found.FullName; $IpaPath = ''; Write-Host "Using the DEB next to the IPA (needed for the video decoder): $DebPath" }
    }
    if ($DebPath -and (Test-Path $DebPath)) {
        Write-Host "Installing DEB $DebPath (into /Applications) ..."
        Invoke-IPad -IPadHost $IPadHost -Command 'ipainstaller -u com.samcejko.gfn6 2>/dev/null; echo ok' | Out-Null
        Copy-ToIPad -LocalPath $DebPath -RemotePath '/tmp/GFN6.deb' -IPadHost $IPadHost
        $out = Invoke-IPad -IPadHost $IPadHost -Command 'dpkg -i /tmp/GFN6.deb 2>&1; su mobile -c uicache 2>/dev/null; echo DEB_OK' | Out-String
        Write-Host $out
        if ($out -match 'DEB_OK') { $installed = $true }
    }
    if (-not $installed -and $IpaPath -and (Test-Path $IpaPath)) {
        Write-Host "WARNING: installing the IPA into the app container - the hardware video decoder will be blocked (black screen). Install the DEB instead."
        Write-Host "Installing IPA $IpaPath ..."
        Copy-ToIPad -LocalPath $IpaPath -RemotePath '/tmp/GFN6.ipa' -IPadHost $IPadHost
        $out = Invoke-IPad -IPadHost $IPadHost -Command 'if command -v ipainstaller >/dev/null 2>&1; then ipainstaller -f /tmp/GFN6.ipa; echo "IPA_EXIT=$?"; elif command -v appinst >/dev/null 2>&1; then appinst /tmp/GFN6.ipa; echo "IPA_EXIT=$?"; else echo NO_INSTALLER; fi' | Out-String
        Write-Host $out
        # ipainstaller's exit code is not reliable; trust its own success message as well.
        if ($out -match 'IPA_EXIT=0' -or $out -match '(?i)installed .* successfully') { $installed = $true }
    }
    if (-not $installed) { throw "Nothing installed" }
    Write-Host "Done. Tap the GFN6 icon on the iPad."
}

function Get-IPadCrashLogs {
    param([string]$IPadHost = $script:IPadDefaultHost, [string]$OutDir = '')
    if (-not $OutDir) { $OutDir = Join-Path (Get-Location) 'packages\crashlogs' }
    New-Item -ItemType Directory -Force -Path $OutDir | Out-Null
    # (the iPad has no head/tail/wc/awk; sed does their work)
    $list = Invoke-IPad -IPadHost $IPadHost -Command "ls -t /var/mobile/Library/Logs/CrashReporter/ 2>/dev/null | grep -i GFN6 | sed -n '1,5p'"
    foreach ($f in (@($list) -join "`n" -split "`n" | Where-Object { $_.Trim() })) {
        $name = $f.Trim()
        Copy-FromIPad -IPadHost $IPadHost -RemotePath "/var/mobile/Library/Logs/CrashReporter/$name" -LocalPath (Join-Path $OutDir $name)
        Write-Host "Fetched $name"
    }
    Get-ChildItem $OutDir -File | Sort-Object LastWriteTime -Descending | Select-Object -First 1
}

function Get-IPadSyslog {
    param([string]$IPadHost = $script:IPadDefaultHost, [int]$Lines = 200)
    $tail = "sed -e :a -e '`$q;N;$($Lines + 1),`$D;ba'"   # (tail -n emulated: the iPad has no tail)
    Invoke-IPad -IPadHost $IPadHost -Command "if [ -f /var/log/syslog ]; then grep -i GFN6 /var/log/syslog | $tail; else echo 'no /var/log/syslog (install the syslogd package from Cydia)'; fi"
}

# The app's own log lines ([GFN6] prefix), the last $Lines of them
function Get-GFN6Log {
    param([int]$Lines = 40, [string]$IPadHost = $script:IPadDefaultHost)
    Invoke-IPad -IPadHost $IPadHost -Command "grep '\[GFN6\]' /var/log/syslog | sed -e :a -e '`$q;N;$($Lines + 1),`$D;ba'"
}

# The app's home folder on the iPad. GFN6 must be installed as the DEB (in /Applications) so the hardware video
# decoder works; a /Applications app's home is /var/mobile. (A container IPA install would be under
# /var/mobile/Applications/<uuid>, kept as a fallback.)
function Get-IPadAppContainer {
    param([string]$IPadHost = $script:IPadDefaultHost)
    $sys = (Invoke-IPad -IPadHost $IPadHost -Command "test -d /Applications/GFN6.app && echo yes" | Out-String).Trim()
    if ($sys -eq 'yes') { return '/var/mobile' }
    $out = (Invoke-IPad -IPadHost $IPadHost -Command "ls -d /var/mobile/Applications/*/GFN6.app 2>/dev/null | sed -n '1p'" | Out-String).Trim()
    if (-not $out) { throw 'GFN6 is not installed on the iPad' }
    $out -replace '/GFN6\.app$', ''
}

# Turns the debug URL commands on (gfn6:snapshot, screen, press, tab, stats, selftest): a file "debug" in the app's Documents
function Enable-GFN6Debug {
    param([string]$IPadHost = $script:IPadDefaultHost)
    $container = Get-IPadAppContainer -IPadHost $IPadHost
    Invoke-IPad -IPadHost $IPadHost -Command "mkdir -p '$container/Documents'; echo on > '$container/Documents/debug'; chown mobile:mobile '$container/Documents/debug'; echo DEBUG_ON" | Out-String
}

# Opens a gfn6: URL in the app (uiopen); -WaitSeconds sleeps on the iPad afterwards so the UI settles
function Invoke-GFN6 {
    param([Parameter(Mandatory = $true)][string]$Url, [int]$WaitSeconds = 0, [string]$IPadHost = $script:IPadDefaultHost)
    $cmd = "uiopen '$Url'"
    if ($WaitSeconds -gt 0) { $cmd += "; sleep $WaitSeconds" }
    Invoke-IPad -IPadHost $IPadHost -Command $cmd
}

# Saves what the iPad shows into a PNG. -Real is the system's screen grab (video included); otherwise the app draws its windows.
function Get-IPadScreen {
    param([Parameter(Mandatory = $true)][string]$OutFile, [switch]$Real, [string]$IPadHost = $script:IPadDefaultHost)
    $kind = if ($Real) { 'screen' } else { 'snapshot' }
    $container = Get-IPadAppContainer -IPadHost $IPadHost
    Invoke-IPad -IPadHost $IPadHost -Command "rm -f /tmp/GFN6-screen.png; uiopen 'gfn6:$kind'; sleep 3; cp '$container/tmp/screen.png' /tmp/GFN6-screen.png" | Out-Null
    Copy-FromIPad -IPadHost $IPadHost -RemotePath '/tmp/GFN6-screen.png' -LocalPath $OutFile
    Get-Item $OutFile
}
