<#
.SYNOPSIS
    Preflight checks for Windows-side Kerberos before DBeaver connects to ora01.

.DESCRIPTION
    Validates DNS resolution, port reachability, clock skew vs the DC,
    and presence of krb5.ini. Returns a [pscustomobject]; emit-only,
    no side effects.

.OUTPUTS
    [pscustomobject] with one bool/string property per check, plus an
    Overall property ('PASS' or 'FAIL').
#>
[CmdletBinding()]
param(
    [string] $DC         = 'ad1.mylab.local',
    [string] $OracleHost = 'ora01.mylab.local',
    [int]    $OraclePort = 1521,
    [int]    $MaxSkewSec = 300
)

$ErrorActionPreference = 'Continue'

function Resolve-Or { param([string]$Name)
    try { (Resolve-DnsName -Name $Name -Type A -ErrorAction Stop)[0].IPAddress } catch { $null }
}

$dcIp  = Resolve-Or $DC
$oraIp = Resolve-Or $OracleHost

$oraTcp   = (Test-NetConnection -ComputerName $OracleHost -Port $OraclePort -WarningAction SilentlyContinue).TcpTestSucceeded
$kdcTcp   = (Test-NetConnection -ComputerName $DC -Port 88   -WarningAction SilentlyContinue).TcpTestSucceeded
$kpwTcp   = (Test-NetConnection -ComputerName $DC -Port 464  -WarningAction SilentlyContinue).TcpTestSucceeded
$ldapsTcp = (Test-NetConnection -ComputerName $DC -Port 636  -WarningAction SilentlyContinue).TcpTestSucceeded

# Full LDAPS handshake + chain validation. Validates against the Windows
# LocalMachine\Root store, so the lab Root CA must be pinned there for this to
# pass. See docs/06-windows-lsa-and-ccache.md or 11-ldaps-cert-trust.md.
$ldapsHandshake = $false
$ldapsCertSubject = $null
$ldapsCertIssuer  = $null
$ldapsCertExpires = $null
$ldapsChainValid  = $null
$ldapsChainError  = $null
$tcp = $null; $ssl = $null
try {
    $tcp = New-Object System.Net.Sockets.TcpClient
    $iar = $tcp.BeginConnect($DC, 636, $null, $null)
    if ($iar.AsyncWaitHandle.WaitOne(5000)) {
        $tcp.EndConnect($iar)
        # Validation callback: capture chain result but do NOT short-circuit.
        $cb = {
            param($s, $cert, $chain, $err)
            $script:ldapsChainValid = ($err -eq [System.Net.Security.SslPolicyErrors]::None)
            if (-not $script:ldapsChainValid) { $script:ldapsChainError = "$err" }
            return $true   # accept anyway so we get the cert details
        }
        $ssl = New-Object System.Net.Security.SslStream($tcp.GetStream(), $false, $cb)
        $ssl.AuthenticateAsClient($DC, $null, [System.Security.Authentication.SslProtocols]::Tls12, $false)
        $ldapsHandshake = $true
        if ($ssl.RemoteCertificate) {
            $c = [System.Security.Cryptography.X509Certificates.X509Certificate2]::new($ssl.RemoteCertificate)
            $ldapsCertSubject = $c.Subject
            $ldapsCertIssuer  = $c.Issuer
            $ldapsCertExpires = $c.NotAfter
        }
    } else {
        $ldapsChainError = 'tcp connect timeout'
    }
} catch {
    $ldapsChainError = $_.Exception.Message
} finally {
    if ($ssl) { $ssl.Dispose() }
    if ($tcp) { $tcp.Close() }
}

# Clock skew vs DC, in seconds.
$skewSec = $null
try {
    $raw = & w32tm /stripchart /computer:$DC /samples:1 /dataonly 2>$null | Select-Object -Last 1
    if ($raw -match ',\s*([-+]?\d+\.\d+)s') { $skewSec = [math]::Abs([double]$Matches[1]) }
} catch { }

$krb5IniSystem = Test-Path 'C:\ProgramData\MIT\Kerberos5\krb5.ini'
$krb5IniLegacy = Test-Path 'C:\Windows\krb5.ini'

# Read ccache from process env first, fall back to registry (User then Machine) so this
# works even when the script was invoked from a shell that inherited stale env.
$ccacheVar = $env:KRB5CCNAME
if (-not $ccacheVar) { $ccacheVar = [Environment]::GetEnvironmentVariable('KRB5CCNAME','User') }
if (-not $ccacheVar) { $ccacheVar = [Environment]::GetEnvironmentVariable('KRB5CCNAME','Machine') }

# Detect MIT KfW by its well-known install path; ignore PATH-order so Eclipse
# Adoptium's bundled kinit.exe doesn't shadow this check.
$mitCandidates = @(
    'C:\Program Files\MIT\Kerberos\bin\kinit.exe',
    'C:\Program Files (x86)\MIT\Kerberos\bin\kinit.exe'
)
$mitKinit = $mitCandidates | Where-Object { Test-Path $_ } | Select-Object -First 1
$isMitKinit = [bool]$mitKinit
$firstKinitOnPath = (Get-Command kinit -ErrorAction SilentlyContinue).Source

$checks = [pscustomobject]@{
    DCResolves       = [bool]$dcIp
    DCIp             = $dcIp
    OracleResolves   = [bool]$oraIp
    OracleIp         = $oraIp
    OracleListener   = $oraTcp
    KDCPort88Tcp     = $kdcTcp
    KpasswdPort464   = $kpwTcp
    LdapsPort636     = $ldapsTcp
    LdapsHandshake   = $ldapsHandshake
    LdapsCertSubject = $ldapsCertSubject
    LdapsCertIssuer  = $ldapsCertIssuer
    LdapsCertExpires = $ldapsCertExpires
    LdapsChainValid  = $ldapsChainValid
    LdapsChainError  = $ldapsChainError
    ClockSkewSec     = $skewSec
    ClockSkewOk      = ($null -ne $skewSec -and $skewSec -lt $MaxSkewSec)
    Krb5IniPresent   = $krb5IniSystem
    Krb5IniLegacy    = $krb5IniLegacy
    KRB5CCNAME       = $ccacheVar
    KRB5CCNAMESet    = [bool]$ccacheVar
    MitKinitInstalled = $isMitKinit
    MitKinitPath      = $mitKinit
    FirstKinitOnPath  = $firstKinitOnPath
}

$failures = @(
    if (-not $checks.DCResolves)     { 'DC DNS' }
    if (-not $checks.OracleResolves) { 'Oracle DNS' }
    if (-not $checks.OracleListener) { 'Oracle 1521' }
    if (-not $checks.KDCPort88Tcp)   { 'KDC 88' }
    if (-not $checks.LdapsPort636)   { 'LDAPS 636' }
    if (-not $checks.LdapsHandshake) { 'LDAPS handshake' }
    if ($checks.LdapsHandshake -and $checks.LdapsChainValid -eq $false) { 'LDAPS chain' }
    if (-not $checks.ClockSkewOk)    { 'clock skew' }
    if (-not $checks.Krb5IniPresent) { 'krb5.ini' }
    if (-not $checks.MitKinitInstalled) { 'MIT kinit installed' }
)

$checks | Add-Member -NotePropertyName Overall -NotePropertyValue ($(if ($failures.Count -eq 0) {'PASS'} else {'FAIL'}))
$checks | Add-Member -NotePropertyName Failed  -NotePropertyValue ($failures -join ', ')
$checks
