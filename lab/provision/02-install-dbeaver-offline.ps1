# Phase 2 (offline): install DBeaver portable and Oracle JDBC jars from a
# bundle that was pre-staged on the host and uploaded by the Vagrantfile
# under C:\Windows\Temp\bundle\. No outbound network access required.
# ASCII-only; non-ASCII breaks guest-side ANSI parse.

$ErrorActionPreference = 'Continue'
$global:ProvisionFailed = $false
function Invoke-Step {
    param([string]$Name, [scriptblock]$Body)
    Write-Host "=== $Name ==="
    try { & $Body }
    catch {
        Write-Host "STEP FAILED ($Name): $($_.Exception.Message)" -ForegroundColor Red
        $global:ProvisionFailed = $true
    }
}

$bundle     = 'C:\Windows\Temp\bundle'
$dbeaverDir = 'C:\Program Files\dbeaver'
$jdbcDir    = 'C:\Users\Public\jdbc\oracle\23.3'

Invoke-Step '02a: Confirm domain join' {
    $cs = Get-CimInstance Win32_ComputerSystem
    Write-Host ("  Computer: {0}  Domain: {1}  PartOfDomain: {2}" -f $cs.Name, $cs.Domain, $cs.PartOfDomain)
    if (-not $cs.PartOfDomain) { throw 'Not domain-joined yet. Phase 1 must complete first.' }
}

Invoke-Step '02b: Verify offline bundle is present' {
    $required = @('dbeaver-portable.zip','ojdbc8.jar','oraclepki.jar','osdt_core.jar','osdt_cert.jar')
    $missing  = $required | Where-Object { -not (Test-Path (Join-Path $bundle $_)) }
    if ($missing) {
        throw "Missing in $bundle : $($missing -join ', '). Re-run tools/stage-offline-bundle.ps1 on a connected PC and re-transfer."
    }
    Get-ChildItem $bundle -File | Select-Object Name, @{N='MB';E={[math]::Round($_.Length/1MB,2)}} | Format-Table -AutoSize
}

Invoke-Step '02c: Validate checksums (if checksums.txt present)' {
    $manifest = Join-Path $bundle 'checksums.txt'
    if (-not (Test-Path $manifest)) {
        Write-Host '  No checksums.txt - skipping integrity check.'
        return
    }
    $verified = 0
    $skipped  = 0
    $bad      = @()
    Get-Content $manifest | ForEach-Object {
        if ($_ -match '^([0-9A-Fa-f]{64})\s+(.+)$') {
            $expected = $Matches[1]
            $relPath  = $Matches[2]
            $path     = Join-Path $bundle $relPath
            if (-not (Test-Path $path)) {
                # Manifest references a file that was not uploaded to this path.
                # That's expected for items the Vagrantfile routes elsewhere
                # (or for optional artifacts like kfw-4.1-amd64.msi). Skip.
                $skipped++
                return
            }
            $actual = (Get-FileHash $path -Algorithm SHA256).Hash
            if ($actual -ne $expected) { $bad += $relPath }
            else { $verified++ }
        }
    }
    if ($bad) { throw "Checksum mismatches: $($bad -join ', ')" }
    Write-Host ("  Verified {0} file(s); skipped {1} not-uploaded entr(ies)." -f $verified, $skipped)
}

Invoke-Step '02d: Extract DBeaver portable' {
    if (Test-Path $dbeaverDir) { Remove-Item $dbeaverDir -Recurse -Force }
    Expand-Archive -Path (Join-Path $bundle 'dbeaver-portable.zip') -DestinationPath 'C:\Program Files' -Force
    if (-not (Test-Path "$dbeaverDir\dbeaver.exe")) {
        $found = Get-ChildItem 'C:\Program Files' -Directory | Where-Object { Test-Path "$($_.FullName)\dbeaver.exe" } | Select-Object -First 1
        if ($found) { Rename-Item $found.FullName $dbeaverDir -Force }
    }
    if (-not (Test-Path "$dbeaverDir\dbeaver.exe")) { throw 'DBeaver extraction did not produce dbeaver.exe' }
    Write-Host "  DBeaver at: $dbeaverDir\dbeaver.exe"
}

Invoke-Step '02e: Stage Oracle JDBC jars from bundle' {
    New-Item -ItemType Directory -Path $jdbcDir -Force | Out-Null
    @('ojdbc8.jar','oraclepki.jar','osdt_core.jar','osdt_cert.jar') | ForEach-Object {
        Copy-Item (Join-Path $bundle $_) (Join-Path $jdbcDir $_) -Force
        Write-Host ("  staged $_  $([math]::Round((Get-Item (Join-Path $jdbcDir $_)).Length/1KB,1)) KB")
    }
}

Invoke-Step '02f: Inject Kerberos JVM args into dbeaver.ini' {
    $iniPath = Join-Path $dbeaverDir 'dbeaver.ini'
    $argsFile = 'C:\Windows\Temp\dbeaver-jvm-args.txt'
    if (-not (Test-Path $argsFile)) { throw "Expected $argsFile (uploaded by Vagrantfile)." }
    # Accept both -D... properties and --add-opens=... lines. The full set is
    # required on Java 17+ (DBeaver 25.x bundles Java 21); without --add-opens
    # entries the Kerberos handshake fails with InaccessibleObjectException.
    $additions = Get-Content $argsFile | Where-Object { $_ -match '^(-D|--add-opens=)' }
    $lines = Get-Content $iniPath
    $keep  = $lines | Where-Object { $additions -notcontains $_.Trim() }
    $out   = New-Object System.Collections.Generic.List[string]
    $injected = $false
    foreach ($l in $keep) {
        $out.Add($l)
        if ($l.Trim() -eq '-vmargs' -and -not $injected) {
            $additions | ForEach-Object { $out.Add($_) }
            $injected = $true
        }
    }
    Set-Content $iniPath -Value $out -Encoding ASCII
    Write-Host "  dbeaver.ini updated."
}

Invoke-Step '02g: Disable update checks (air-gapped guard)' {
    # DBeaver's runtime update poll never reaches the internet here, but we'd
    # rather not have it show error dialogs to the analyst either. Disable both
    # the auto-update preference and the eclipse p2 repositories.
    $prefDir  = Join-Path $env:APPDATA 'DBeaverData\workspace6\.metadata\.plugins\org.eclipse.core.runtime\.settings'
    New-Item -ItemType Directory -Path $prefDir -Force | Out-Null
    @"
eclipse.preferences.version=1
notification.update.enabled=false
update.disabled=true
"@ | Set-Content (Join-Path $prefDir 'org.jkiss.dbeaver.core.prefs') -Encoding ASCII
    Write-Host "  Wrote pref to disable update checks for the next user (alice)."
}

Invoke-Step '02h: Public Desktop shortcut for DBeaver' {
    $ws  = New-Object -ComObject WScript.Shell
    $lnk = $ws.CreateShortcut('C:\Users\Public\Desktop\DBeaver.lnk')
    $lnk.TargetPath = "$dbeaverDir\dbeaver.exe"
    $lnk.WorkingDirectory = $dbeaverDir
    $lnk.Save()
}

if ($global:ProvisionFailed) {
    Write-Host 'One or more steps failed. See messages above.' -ForegroundColor Red
    exit 1
}

Write-Host ""
Write-Host "=== Provisioning complete (offline mode). ==="
Write-Host "JDBC jars staged at $jdbcDir"
Write-Host "DBeaver at $dbeaverDir\dbeaver.exe (no internet access required)"
Write-Host "Next: in the VirtualBox console, switch user to MYLAB\alice and open DBeaver."
exit 0
