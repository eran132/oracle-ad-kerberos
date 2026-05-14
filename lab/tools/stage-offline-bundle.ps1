<#
.SYNOPSIS
    Build an offline-install bundle for the air-gapped wks01 workflow.

.DESCRIPTION
    Run this on an INTERNET-CONNECTED PC. It populates the lab/bundle/
    directory with every binary, jar, and cert needed to provision wks01
    (and optionally a non-domain-joined Windows host) without further
    network access.

    Resulting layout:
        lab/bundle/
        |-- dbeaver-portable.zip      (~123 MB)
        |-- ojdbc8.jar                (6.7 MB)
        |-- oraclepki.jar             (470 KB)
        |-- osdt_core.jar             (305 KB)
        |-- osdt_cert.jar             (206 KB)
        |-- kfw-4.1-amd64.msi         (10.6 MB - only with -IncludeMitKfw)
        |-- mylab-root-ca.cer         (copied from ../config/windows/trust/)
        |-- mylab-root-ca.pem
        |-- corp-proxy-CAs/*.crt      (copied from ../../tableau_ad_oracle/ca/)
        `-- checksums.txt

    After running, transfer the entire lab/bundle/ directory to your
    air-gapped network (USB, SFTP, network share, courier - whatever you
    use). On the air-gapped target, set $env:LAB_OFFLINE=1 before
    `vagrant up wks01`.

.PARAMETER IncludeMitKfw
    Also download the MIT Kerberos for Windows MSI (only relevant if you
    plan to use a non-domain-joined Windows machine in the air-gapped env).

.PARAMETER DbeaverVersion
    Override the DBeaver version. Default is the latest GA available on
    dbeaver.io.

.PARAMETER OjdbcVersion
    Override the ojdbc8/oraclepki version. Default 23.3.0.23.09 (compatible
    with Oracle 19c and 21c).

.PARAMETER OsdtVersion
    Override osdt_core/osdt_cert version. Default 21.9.0.0 (latest on Maven
    Central; matched with ojdbc8 23.x by convention).
#>
[CmdletBinding()]
param(
    [switch] $IncludeMitKfw,
    [string] $DbeaverVersion,
    [string] $OjdbcVersion = '23.3.0.23.09',
    [string] $OsdtVersion  = '21.9.0.0'
)

$ErrorActionPreference = 'Stop'
$ProgressPreference    = 'SilentlyContinue'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 -bor [Net.SecurityProtocolType]::Tls13

# $PSCommandPath = ...\oracle_Ad_kerberos\lab\tools\stage-offline-bundle.ps1
# Walk up:                                         ...\lab\tools  ->  ...\lab  ->  ...\oracle_Ad_kerberos
$labDir    = Split-Path -Parent (Split-Path -Parent $PSCommandPath)
$repoRoot  = Split-Path -Parent $labDir
$bundleDir = Join-Path $labDir  'bundle'
$corpCaSrc = Join-Path $repoRoot '..\tableau_ad_oracle\ca'
$labCaSrc  = Join-Path $repoRoot 'config\windows\trust'

New-Item -ItemType Directory -Path $bundleDir -Force | Out-Null
$corpDest = Join-Path $bundleDir 'corp-proxy-CAs'
New-Item -ItemType Directory -Path $corpDest -Force | Out-Null

function Fetch {
    param([string]$Url, [string]$OutPath, [string]$Label)
    if (Test-Path $OutPath) {
        Write-Host ("  SKIP {0,-25} (already present, {1:N1} MB)" -f $Label, ((Get-Item $OutPath).Length/1MB))
        return
    }
    Write-Host ("  GET  {0,-25} <- {1}" -f $Label, $Url)
    Invoke-WebRequest -Uri $Url -OutFile $OutPath -UseBasicParsing
    $sz = (Get-Item $OutPath).Length
    Write-Host ("       wrote {0,8:N1} KB" -f ($sz/1KB))
}

Write-Host "=== Resolving DBeaver portable zip URL ==="
if (-not $DbeaverVersion) {
    $rels = Invoke-RestMethod 'https://api.github.com/repos/dbeaver/dbeaver/releases?per_page=20' -UseBasicParsing
    foreach ($r in $rels) {
        $v = $r.tag_name.TrimStart('v')
        $u = "https://dbeaver.io/files/$v/dbeaver-ce-$v-win32.win32.x86_64.zip"
        try {
            $null = Invoke-WebRequest -Uri $u -Method Head -UseBasicParsing -TimeoutSec 8 -ErrorAction Stop
            $DbeaverVersion = $v
            break
        } catch {}
    }
    if (-not $DbeaverVersion) { throw 'Could not resolve a DBeaver portable URL.' }
}
$dbeaverUrl = "https://dbeaver.io/files/$DbeaverVersion/dbeaver-ce-$DbeaverVersion-win32.win32.x86_64.zip"
Write-Host "Selected DBeaver: $DbeaverVersion"

Write-Host ""
Write-Host "=== Downloading binaries to $bundleDir ==="
Fetch -Url $dbeaverUrl -OutPath (Join-Path $bundleDir 'dbeaver-portable.zip') -Label 'dbeaver-portable.zip'

$mvnBase = 'https://repo1.maven.org/maven2/com/oracle/database'
Fetch -Url "$mvnBase/jdbc/ojdbc8/$OjdbcVersion/ojdbc8-$OjdbcVersion.jar"          -OutPath (Join-Path $bundleDir 'ojdbc8.jar')        -Label 'ojdbc8.jar'
Fetch -Url "$mvnBase/security/oraclepki/$OjdbcVersion/oraclepki-$OjdbcVersion.jar" -OutPath (Join-Path $bundleDir 'oraclepki.jar')     -Label 'oraclepki.jar'
Fetch -Url "$mvnBase/security/osdt_core/$OsdtVersion/osdt_core-$OsdtVersion.jar"  -OutPath (Join-Path $bundleDir 'osdt_core.jar')     -Label 'osdt_core.jar'
Fetch -Url "$mvnBase/security/osdt_cert/$OsdtVersion/osdt_cert-$OsdtVersion.jar"  -OutPath (Join-Path $bundleDir 'osdt_cert.jar')     -Label 'osdt_cert.jar'

if ($IncludeMitKfw) {
    Fetch -Url 'https://web.mit.edu/kerberos/dist/kfw/4.1/kfw-4.1-amd64.msi' -OutPath (Join-Path $bundleDir 'kfw-4.1-amd64.msi') -Label 'kfw-4.1-amd64.msi'
}

Write-Host ""
Write-Host "=== Copying lab Root CA from repo ==="
if (Test-Path $labCaSrc) {
    Get-ChildItem $labCaSrc -Filter 'mylab-root-ca.*' | ForEach-Object {
        Copy-Item $_.FullName (Join-Path $bundleDir $_.Name) -Force
        Write-Host ("  copied {0}" -f $_.Name)
    }
} else {
    Write-Host "  WARN  $labCaSrc not present. Run the AD CS chapter first to generate mylab-root-ca."
}

Write-Host ""
Write-Host "=== Copying corporate proxy CAs from sibling repo (if present) ==="
if (Test-Path $corpCaSrc) {
    Get-ChildItem $corpCaSrc -Filter '*.crt' -ErrorAction SilentlyContinue | ForEach-Object {
        Copy-Item $_.FullName (Join-Path $corpDest $_.Name) -Force
        Write-Host ("  copied corp-proxy-CAs/{0}" -f $_.Name)
    }
} else {
    Write-Host "  (no sibling tableau_ad_oracle/ca - skipping. fine for non-corp networks.)"
}

Write-Host ""
Write-Host "=== Generating checksums.txt ==="
# Only hash files the Vagrantfile actually uploads to C:\Windows\Temp\bundle\
# on the guest (the install binaries). Excludes repo bookkeeping (.gitignore,
# README.md) and the corp-proxy-CAs/ subdir (which goes to a different path
# inside the guest as C:\Windows\Temp\corp-*.crt).
$included = @('dbeaver-portable.zip','ojdbc8.jar','oraclepki.jar','osdt_core.jar',
              'osdt_cert.jar','mylab-root-ca.cer','mylab-root-ca.pem','kfw-4.1-amd64.msi')
$manifest = Get-ChildItem $bundleDir -File | Where-Object { $included -contains $_.Name } |
    Sort-Object Name | ForEach-Object {
        $hash = (Get-FileHash $_.FullName -Algorithm SHA256).Hash
        "$hash  $($_.Name)"
    }
$manifest | Set-Content (Join-Path $bundleDir 'checksums.txt') -Encoding ASCII
$manifest | ForEach-Object { Write-Host "  $_" }

Write-Host ""
Write-Host "=== Bundle ready ==="
$total = (Get-ChildItem $bundleDir -Recurse -File | Measure-Object -Property Length -Sum).Sum
Write-Host ("Total bundle size: {0:N1} MB at $bundleDir" -f ($total/1MB))
Write-Host ""
Write-Host "Transfer $bundleDir to your air-gapped network, drop it back at the same"
Write-Host "relative path inside an offline copy of this repo, then on the target:"
Write-Host ""
Write-Host "    cd lab"
Write-Host "    `$env:LAB_OFFLINE = '1'"
Write-Host "    `$env:AD_ADMIN_PW = '<the Administrator password>'"
Write-Host "    vagrant up wks01"
