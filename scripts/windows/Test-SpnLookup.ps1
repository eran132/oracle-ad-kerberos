<#
.SYNOPSIS
    Verifies the Oracle SPN exists exactly once on the right AD account
    and the account is enabled for AES Kerberos encryption.

.DESCRIPTION
    AD queries (LDAP, setspn) require an authenticated Kerberos context.
    This script first checks for a TGT in the current ccache:
      - No TGT -> Overall = 'SKIP' with a hint to run `kinit` first
      - TGT present -> runs setspn -L (forward), -Q (reverse uniqueness), and
        if RSAT is installed, an LDAPS-bound Get-ADUser to validate AES enctypes.

.PARAMETER Account
    AD account expected to hold the SPN. Default: svc-ora01.

.PARAMETER ServiceSpn
    SPN to look up. Default: oracle/ora01.mylab.local.

.OUTPUTS
    [pscustomobject]
#>
[CmdletBinding()]
param(
    [string] $Account    = 'svc-ora01',
    [string] $ServiceSpn = 'oracle/ora01.mylab.local',
    [string] $DC         = 'ad1.mylab.local'
)

function Get-MitTool([string]$name) {
    $cand = Get-Command $name -ErrorAction SilentlyContinue | Where-Object { $_.Source -like '*MIT*Kerberos*' } | Select-Object -First 1
    if ($cand) { return $cand.Source }
    $fixed = "C:\Program Files\MIT\Kerberos\bin\$name.exe"
    if (Test-Path $fixed) { return $fixed }
    return $null
}

# Check for a TGT before attempting any AD query.
$klistMit = Get-MitTool 'klist'
$hasTgt = $false
$principal = $null
if ($klistMit) {
    $klOut = (& $klistMit 2>&1) -join "`n"
    if ($klOut -match 'krbtgt/MYLAB\.LOCAL@MYLAB\.LOCAL') {
        $hasTgt = $true
        if ($klOut -match 'Default principal:\s*(\S+)') { $principal = $Matches[1] }
    }
}

if (-not $hasTgt) {
    return [pscustomobject]@{
        Account             = $Account
        ServiceSpn          = $ServiceSpn
        Principal           = $null
        SpnOnAccount        = $null
        UniqueRegistrations = $null
        UniqueOk            = $null
        AES256Bit           = $null
        EnctypeBitmask      = $null
        Overall             = 'SKIP'
        Hint                = 'No TGT in ccache. Run `kinit alice@MYLAB.LOCAL` (or use -DoKinit on Invoke-DBeaverPrecheck) first.'
    }
}

$setspn = Join-Path $env:WINDIR 'System32\setspn.exe'
if (-not (Test-Path $setspn)) { throw 'setspn.exe not found.' }

# Forward lookup: SPN appears on the expected account
$onAccount = & $setspn -L $Account 2>&1
$onAccountHit = ($onAccount -join "`n") -match [regex]::Escape($ServiceSpn)

# Reverse lookup: must return exactly one account
$reverse = & $setspn -Q $ServiceSpn 2>&1
$hitCount = (($reverse -join "`n") | Select-String -Pattern 'CN=' -AllMatches).Matches.Count
if ($hitCount -eq 0) { $hitCount = (($reverse -join "`n") | Select-String -Pattern $ServiceSpn -AllMatches).Matches.Count }

# Encryption-type check via LDAPS bind (if RSAT is present).
$enctypesOk = $null
$enctypesRaw = $null
if (Get-Module -ListAvailable -Name ActiveDirectory) {
    Import-Module ActiveDirectory -ErrorAction SilentlyContinue
    try {
        $u = Get-ADUser -Server "$($DC):636" -Identity $Account -Properties 'msDS-SupportedEncryptionTypes','servicePrincipalName'
        $bitmask = [int]($u.'msDS-SupportedEncryptionTypes')
        # 0x10 = AES256_CTS_HMAC_SHA1_96 ; 0x08 = AES128_CTS_HMAC_SHA1_96
        $enctypesOk  = ($bitmask -band 0x10) -ne 0
        $enctypesRaw = $bitmask
    } catch {
        $enctypesRaw = "Get-ADUser via LDAPS failed: $($_.Exception.Message)"
    }
} else {
    $enctypesRaw = 'RSAT ActiveDirectory module not installed (optional)'
}

$pass = $onAccountHit -and ($hitCount -eq 1) -and ($enctypesOk -ne $false)
[pscustomobject]@{
    Account             = $Account
    ServiceSpn          = $ServiceSpn
    Principal           = $principal
    SpnOnAccount        = $onAccountHit
    UniqueRegistrations = $hitCount
    UniqueOk            = ($hitCount -eq 1)
    AES256Bit           = $enctypesOk
    EnctypeBitmask      = $enctypesRaw
    Overall             = $(if ($pass) { 'PASS' } else { 'FAIL' })
    Hint                = $null
}
