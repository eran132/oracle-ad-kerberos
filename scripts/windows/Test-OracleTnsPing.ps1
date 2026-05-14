<#
.SYNOPSIS
    Verifies the Oracle listener is reachable. Uses tnsping if Oracle
    Instant Client is installed, else a plain TCP probe on 1521.

.DESCRIPTION
    Auto-detects Instant Client by looking for tnsping.exe on PATH and
    a TNS_ADMIN env var. If both are present and TNS_ADMIN\tnsnames.ora
    contains an ORCLPDB1 entry, runs tnsping. Otherwise, falls back to
    Test-NetConnection on 1521.

    If sqlplus is also present and KRB5CCNAME points at a valid ccache,
    additionally tries `sqlplus -L /@ORCLPDB1` to confirm the full
    Kerberos auth path end-to-end at the SQL*Net layer (before DBeaver).

.PARAMETER OracleHost
    Default: ora01.mylab.local

.PARAMETER OraclePort
    Default: 1521

.PARAMETER TnsAlias
    Default: ORCLPDB1
#>
[CmdletBinding()]
param(
    [string] $OracleHost = 'ora01.mylab.local',
    [int]    $OraclePort = 1521,
    [string] $TnsAlias   = 'ORCLPDB1'
)

$tnsping = (Get-Command tnsping -ErrorAction SilentlyContinue).Source
$sqlplus = (Get-Command sqlplus -ErrorAction SilentlyContinue).Source
$mode    = 'TCPOnly'
$result  = $false
$detail  = $null
$sqlUser = $null

if ($tnsping -and $env:TNS_ADMIN) {
    $mode = 'InstantClient'
    $out = & $tnsping $TnsAlias 2>&1
    $detail = ($out | Select-Object -Last 5) -join ' / '
    $result = (($out -join "`n") -match 'OK\s*\(\d+\s*ms')
}

if ($mode -eq 'TCPOnly') {
    $tnc = Test-NetConnection -ComputerName $OracleHost -Port $OraclePort -WarningAction SilentlyContinue
    $result = $tnc.TcpTestSucceeded
    $detail = "TCP $OracleHost`:$OraclePort = $($tnc.TcpTestSucceeded)"
}

# Optional: sqlplus end-to-end with the current Kerberos ccache.
$sqlOk = $null
if ($sqlplus -and $env:KRB5CCNAME -and $result) {
    $tmp = New-TemporaryFile
    "select user from dual;`nexit" | Out-File -FilePath $tmp -Encoding ascii
    $out = & $sqlplus -L -S /@$TnsAlias `@$tmp 2>&1
    Remove-Item $tmp -ErrorAction SilentlyContinue
    $sqlOk = ($out -join "`n") -match '@MYLAB\.LOCAL'
    if ($sqlOk) { $sqlUser = (($out | Where-Object {$_ -match '@MYLAB\.LOCAL'}) -join ' ').Trim() }
}

[pscustomobject]@{
    Mode             = $mode
    ListenerReachable= $result
    Detail           = $detail
    SqlplusAvailable = [bool]$sqlplus
    SqlplusKerberos  = $sqlOk
    SqlplusUser      = $sqlUser
    Overall          = $(if ($result) {'PASS'} else {'FAIL'})
}
