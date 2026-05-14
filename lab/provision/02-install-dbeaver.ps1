# Phase 2: install DBeaver portable, stage Oracle JDBC jars, wire dbeaver.ini.
# Runs after the reboot from phase 1. Computer is now MYLAB\wks01.
# NOTE: ASCII-only intentionally; non-ASCII breaks guest-side ANSI parse.

$ErrorActionPreference = 'Stop'

$dbeaverDir = 'C:\Program Files\dbeaver'
$jdbcDir    = 'C:\Users\Public\jdbc\oracle\23.3'
$ProgressPreference = 'SilentlyContinue'

# PowerShell 5.1 defaults to TLS 1.0/1.1; force 1.2 for GitHub/Maven/dbeaver.io.
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 -bor [Net.SecurityProtocolType]::Tls13

Write-Host "=== 02a: Confirm domain join ==="
$cs = Get-CimInstance Win32_ComputerSystem
"Computer: $($cs.Name)  Domain: $($cs.Domain)  PartOfDomain: $($cs.PartOfDomain)"
if (-not $cs.PartOfDomain) { throw "Not domain-joined yet. Phase 1 must complete first." }

Write-Host "=== 02b: Download DBeaver portable zip ==="
$rels = Invoke-RestMethod 'https://api.github.com/repos/dbeaver/dbeaver/releases?per_page=20' -UseBasicParsing
$dlUrl = $null
foreach ($r in $rels) {
    $v = $r.tag_name.TrimStart('v')
    $u = "https://dbeaver.io/files/$v/dbeaver-ce-$v-win32.win32.x86_64.zip"
    try { $null = Invoke-WebRequest -Uri $u -Method Head -UseBasicParsing -TimeoutSec 8 -ErrorAction Stop
          $dlUrl = $u; break } catch {}
}
if (-not $dlUrl) { throw 'Could not resolve a DBeaver portable zip URL.' }
$zip = "$env:TEMP\dbeaver-portable.zip"
Write-Host "Downloading $dlUrl"
Invoke-WebRequest -Uri $dlUrl -OutFile $zip -UseBasicParsing
Write-Host "$([math]::Round((Get-Item $zip).Length/1MB,1)) MB"

Write-Host "=== 02c: Extract DBeaver portable ==="
if (Test-Path $dbeaverDir) { Remove-Item $dbeaverDir -Recurse -Force }
Expand-Archive -Path $zip -DestinationPath 'C:\Program Files' -Force
# Portable zip extracts to a `dbeaver` folder by default.
if (-not (Test-Path "$dbeaverDir\dbeaver.exe")) {
    # Fall back to whatever subfolder the zip created.
    $found = Get-ChildItem 'C:\Program Files' -Directory | Where-Object { Test-Path "$($_.FullName)\dbeaver.exe" } | Select-Object -First 1
    if ($found) { Rename-Item $found.FullName $dbeaverDir -Force }
}
if (-not (Test-Path "$dbeaverDir\dbeaver.exe")) { throw 'DBeaver extraction did not produce dbeaver.exe' }

Write-Host "=== 02d: Stage Oracle JDBC jars ==="
New-Item -ItemType Directory -Path $jdbcDir -Force | Out-Null
$base = 'https://repo1.maven.org/maven2/com/oracle/database'
@(
    @{U="$base/jdbc/ojdbc8/23.3.0.23.09/ojdbc8-23.3.0.23.09.jar";          F='ojdbc8.jar'}
    @{U="$base/security/oraclepki/23.3.0.23.09/oraclepki-23.3.0.23.09.jar"; F='oraclepki.jar'}
    @{U="$base/security/osdt_core/21.9.0.0/osdt_core-21.9.0.0.jar";        F='osdt_core.jar'}
    @{U="$base/security/osdt_cert/21.9.0.0/osdt_cert-21.9.0.0.jar";        F='osdt_cert.jar'}
) | ForEach-Object {
    $out = Join-Path $jdbcDir $_.F
    Invoke-WebRequest -Uri $_.U -OutFile $out -UseBasicParsing
    "  $($_.F)  $([math]::Round((Get-Item $out).Length/1KB,1)) KB"
}

Write-Host "=== 02e: Inject Kerberos JVM args into dbeaver.ini ==="
$iniPath = Join-Path $dbeaverDir 'dbeaver.ini'
# Accept both -D... properties and --add-opens=... lines. The full --add-opens
# set is required on Java 17+ (DBeaver 25.x bundles Java 21); without those
# entries the Kerberos handshake fails with InaccessibleObjectException.
$additions = Get-Content 'C:\Windows\Temp\dbeaver-jvm-args.txt' | Where-Object { $_ -match '^(-D|--add-opens=)' }
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
Write-Host "dbeaver.ini updated. First 30 lines:"
Get-Content $iniPath | Select-Object -First 30

Write-Host "=== 02f: Create Public Desktop shortcut for DBeaver ==="
$ws  = New-Object -ComObject WScript.Shell
$lnk = $ws.CreateShortcut('C:\Users\Public\Desktop\DBeaver.lnk')
$lnk.TargetPath = "$dbeaverDir\dbeaver.exe"
$lnk.WorkingDirectory = $dbeaverDir
$lnk.Save()

Write-Host ""
Write-Host "=== Provisioning complete. ==="
Write-Host "Next: in the VirtualBox console window for wks01, switch user to MYLAB\alice"
Write-Host "and double-click the DBeaver shortcut on the Desktop. JDBC jars at:"
Write-Host "  $jdbcDir"
