<#
.SYNOPSIS
    Acquires a TGT and an Oracle service ticket using MIT kinit/kvno.

.DESCRIPTION
    Runs kinit for $User@$Realm (prompts for password interactively),
    then klist, then kvno for the Oracle SPN. Returns a structured result.

.PARAMETER User
    AD sAMAccountName (without realm). Default: alice.

.PARAMETER Realm
    Kerberos realm. Default: MYLAB.LOCAL.

.PARAMETER ServiceSpn
    Service principal to request a ticket for.
    Default: oracle/ora01.mylab.local@MYLAB.LOCAL

.OUTPUTS
    [pscustomobject] { Principal, TGT, ServiceTicket, KvnoOutput, Overall }
#>
[CmdletBinding()]
param(
    [string] $User       = 'alice',
    [string] $Realm      = 'MYLAB.LOCAL',
    [string] $ServiceSpn = 'oracle/ora01.mylab.local@MYLAB.LOCAL'
)

$principal = "$User@$Realm"

# Locate MIT Kerberos tools (not the Windows native klist).
$kinit = (Get-Command kinit -ErrorAction SilentlyContinue).Source
$klist = (Get-Command klist -ErrorAction SilentlyContinue).Source
$kvno  = (Get-Command kvno  -ErrorAction SilentlyContinue).Source
if (-not $kinit -or $kinit -notlike '*MIT*') {
    throw 'MIT Kerberos for Windows kinit not on PATH. See docs/05-windows-client-mit-krb.md.'
}
# Windows native klist lives in System32 and has different output; prefer MIT's.
if ($klist -notlike '*MIT*') { $klist = Join-Path (Split-Path $kinit) 'klist.exe' }
if ($kvno  -notlike '*MIT*') { $kvno  = Join-Path (Split-Path $kinit) 'kvno.exe'  }

Write-Host "kinit $principal (interactive password prompt follows)" -ForegroundColor Cyan
& $kinit $principal
$kinitRc = $LASTEXITCODE

$klistOut = & $klist 2>&1
$hasTgt = ($klistOut -join "`n") -match "krbtgt/$Realm@$Realm"

$kvnoOut = & $kvno $ServiceSpn 2>&1
$kvnoRc  = $LASTEXITCODE
$hasSt   = ($kvnoRc -eq 0) -and (($kvnoOut -join "`n") -match 'kvno\s*=\s*\d+')

$result = [pscustomobject]@{
    Principal      = $principal
    KinitExit      = $kinitRc
    TGT            = $hasTgt
    KvnoExit       = $kvnoRc
    ServiceTicket  = $hasSt
    KvnoOutput     = ($kvnoOut -join ' ').Trim()
    KlistTicketLine= ($klistOut | Select-String -Pattern 'Ticket cache' | Select-Object -First 1).Line
    Overall        = $(if ($hasTgt -and $hasSt) {'PASS'} else {'FAIL'})
}
$result
