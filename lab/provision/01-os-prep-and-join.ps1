# Phase 1: prep the Windows guest and join it to mylab.local.
# Runs as SYSTEM via WinRM. Reboots at the end.
# NOTE: ASCII-only; non-ASCII breaks guest-side ANSI parse.
#
# Native commands (reg.exe, w32tm) sometimes write success messages to stderr;
# we use $ErrorActionPreference='Continue' globally and check $LASTEXITCODE
# explicitly to avoid PowerShell escalating stderr text to a terminating error.

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

$adAdminUser = $env:AD_ADMIN_USER
$adAdminPw   = $env:AD_ADMIN_PW
if (-not $adAdminUser -or -not $adAdminPw) {
    Write-Host "AD_ADMIN_USER / AD_ADMIN_PW env vars not set inside guest. Check Vagrantfile." -ForegroundColor Red
    exit 1
}

Invoke-Step '01a: Point host-only NIC DNS at ad1' {
    $hostOnly = Get-NetIPAddress -AddressFamily IPv4 -IPAddress '192.168.56.40' -ErrorAction SilentlyContinue
    if (-not $hostOnly) { throw 'Host-only NIC did not come up at 192.168.56.40.' }
    Set-DnsClientServerAddress -InterfaceIndex $hostOnly.InterfaceIndex -ServerAddresses '192.168.56.10'
    Get-DnsClientServerAddress -InterfaceIndex $hostOnly.InterfaceIndex | Format-Table InterfaceAlias, ServerAddresses
}

Invoke-Step '01b: Sync time to ad1 (under 5 min skew required for Kerberos)' {
    $null = w32tm /config /manualpeerlist:'ad1.mylab.local,0x9' /syncfromflags:manual /reliable:no /update 2>$null
    Restart-Service w32time -Force
    Start-Sleep -Seconds 3
    # First resync often returns "no time data available" while w32time warms up.
    # Try twice; ignore exit codes; final state is good enough for domain join.
    1..2 | ForEach-Object {
        $out = w32tm /resync /force 2>&1
        Write-Host "  resync attempt ${_}: $($out -join ' / ')"
        Start-Sleep -Seconds 3
    }
}

Invoke-Step '01c: Hosts file fallback entries' {
    $hostsFile = 'C:\Windows\System32\drivers\etc\hosts'
    $additions = @(
        '192.168.56.10  ad1.mylab.local  ad1'
        '192.168.56.20  ora01.mylab.local ora01'
    )
    $cur = Get-Content $hostsFile -Raw
    foreach ($e in $additions) {
        if ($cur -notmatch [regex]::Escape($e)) { Add-Content -Path $hostsFile -Value $e }
    }
}

Invoke-Step '01d: Pin lab Root CA into LocalMachine\Root' {
    Import-Certificate -FilePath 'C:\Windows\Temp\mylab-root-ca.cer' -CertStoreLocation Cert:\LocalMachine\Root |
        Format-List Subject, Thumbprint
}

Invoke-Step '01d2: Pin corporate proxy CAs (Bluecoat/Symantec) so HTTPS works through the host MITM proxy' {
    $corpCAs = Get-ChildItem 'C:\Windows\Temp\corp-*.crt' -ErrorAction SilentlyContinue
    if (-not $corpCAs) {
        Write-Host '  No corp-*.crt files uploaded (sibling tableau_ad_oracle/ca empty or missing). Skipping.'
        return
    }
    foreach ($f in $corpCAs) {
        $c = Import-Certificate -FilePath $f.FullName -CertStoreLocation Cert:\LocalMachine\Root
        Write-Host ("  Imported: {0}" -f $c.Subject)
    }
}

Invoke-Step '01e: Drop krb5.ini for optional MIT KfW fallback' {
    New-Item -ItemType Directory -Path 'C:\ProgramData\MIT\Kerberos5' -Force | Out-Null
    Copy-Item 'C:\Windows\Temp\krb5.ini' 'C:\ProgramData\MIT\Kerberos5\krb5.ini' -Force
}

Invoke-Step '01f: Apply allowtgtsessionkey LSA tweak' {
    # reg import writes success to stderr; discard both streams and check exit code.
    $null = & reg.exe import 'C:\Windows\Temp\allowtgtsessionkey.reg' 2>&1
    if ($LASTEXITCODE -ne 0) { throw "reg import failed: exit code $LASTEXITCODE" }
    $v = (Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\Lsa\Kerberos\Parameters' -ErrorAction SilentlyContinue).allowtgtsessionkey
    Write-Host "  allowtgtsessionkey = $v (expect 1)"
}

Invoke-Step '01g: Rename to wks01 and join mylab.local' {
    $sec  = ConvertTo-SecureString $adAdminPw -AsPlainText -Force
    $cred = New-Object System.Management.Automation.PSCredential($adAdminUser, $sec)
    $current = Get-CimInstance Win32_ComputerSystem
    if ($current.PartOfDomain -and $current.Domain -eq 'mylab.local') {
        Write-Host "  Already domain-joined as $($current.Name).$($current.Domain); nothing to do."
        return
    }
    # Rename separately (queues for next boot). Skip if already named wks01.
    if ($current.Name -ne 'wks01') {
        Write-Host "  Renaming '$($current.Name)' -> 'wks01' (applies on reboot)"
        Rename-Computer -NewName 'wks01' -Force -ErrorAction Stop
    } else {
        Write-Host "  Name already 'wks01'; no rename needed."
    }
    # Join domain. DO NOT pass -NewName here when names already match; Add-Computer
    # treats that as "no-op" and refuses to do anything else either.
    Write-Host '  Add-Computer -DomainName mylab.local ...'
    Add-Computer -DomainName 'mylab.local' -Credential $cred -Force -ErrorAction Stop
    Write-Host '  Domain join queued. Vagrant will reboot the VM after this script returns.'
}

if ($global:ProvisionFailed) {
    Write-Host 'One or more steps failed. See messages above.' -ForegroundColor Red
    exit 1
}
exit 0
