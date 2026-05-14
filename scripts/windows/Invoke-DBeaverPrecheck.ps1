<#
.SYNOPSIS
    One-command preflight before opening DBeaver against the AD/Kerberos lab.

.DESCRIPTION
    Runs Test-KerberosPrereqs, Test-SpnLookup, Test-OracleTnsPing, and
    (optionally, if -DoKinit) Test-Kinit. Prints a Format-Table summary
    and exits 0 on all-pass, 1 on any failure.

    The kinit step is gated behind a switch because it prompts for a
    password interactively; the other three are non-interactive and
    safe to run unattended.

.PARAMETER DoKinit
    Also run Test-Kinit. Will prompt for $User's AD password.

.PARAMETER User
    Default: alice. Only used when -DoKinit is set.

.EXAMPLE
    # Non-interactive: DNS, ports, clock, SPN, listener
    .\Invoke-DBeaverPrecheck.ps1

.EXAMPLE
    # Full check including kinit + kvno
    .\Invoke-DBeaverPrecheck.ps1 -DoKinit -User alice
#>
[CmdletBinding()]
param(
    [switch] $DoKinit,
    [string] $User = 'alice'
)

$here = Split-Path -Parent $PSCommandPath

Write-Host "=== Test-KerberosPrereqs ===" -ForegroundColor Cyan
$prereqs = & (Join-Path $here 'Test-KerberosPrereqs.ps1')
$prereqs | Format-List

Write-Host "=== Test-SpnLookup ===" -ForegroundColor Cyan
$spn = & (Join-Path $here 'Test-SpnLookup.ps1')
$spn | Format-List

Write-Host "=== Test-OracleTnsPing ===" -ForegroundColor Cyan
$tns = & (Join-Path $here 'Test-OracleTnsPing.ps1')
$tns | Format-List

$kinit = $null
if ($DoKinit) {
    Write-Host "=== Test-Kinit (-User $User) ===" -ForegroundColor Cyan
    $kinit = & (Join-Path $here 'Test-Kinit.ps1') -User $User
    $kinit | Format-List
}

# Summary table
$summary = @(
    [pscustomobject]@{ Check='Prereqs (DNS/ports/clock/krb5.ini)'; Result=$prereqs.Overall; Detail=$prereqs.Failed }
    [pscustomobject]@{ Check='SPN registration + AES enctype';     Result=$spn.Overall;     Detail="unique=$($spn.UniqueRegistrations) aes256=$($spn.AES256Bit)" }
    [pscustomobject]@{ Check='Oracle listener reachable';          Result=$tns.Overall;     Detail=$tns.Detail }
)
if ($kinit) {
    $summary += [pscustomobject]@{ Check="kinit + kvno ($($kinit.Principal))"; Result=$kinit.Overall; Detail="tgt=$($kinit.TGT) st=$($kinit.ServiceTicket)" }
}

Write-Host ""
Write-Host "=== Summary ===" -ForegroundColor Cyan
$summary | Format-Table -AutoSize

$anyFail = $summary | Where-Object { $_.Result -eq 'FAIL' }
$anySkip = $summary | Where-Object { $_.Result -eq 'SKIP' }
if ($anyFail) {
    Write-Host "FAILED checks: $($anyFail.Check -join ', ')" -ForegroundColor Red
    Write-Host "See troubleshooting.md for diagnosis." -ForegroundColor Red
    exit 1
}
if ($anySkip) {
    Write-Host "SKIPPED checks: $($anySkip.Check -join ', ')" -ForegroundColor Yellow
    Write-Host "All non-skipped checks passed. Re-run with -DoKinit to validate the skipped ones." -ForegroundColor Yellow
    exit 0
}
Write-Host "All checks passed. Open DBeaver and connect to ORCLPDB1." -ForegroundColor Green
exit 0
