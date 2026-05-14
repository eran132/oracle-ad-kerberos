# 12 · Install record — what was installed, where, and from what source

A precise record of every binary, certificate, and configuration installed to make this lab work on the Windows host and the two VMs. Reproducible: re-running the same sources with the same versions should land you in the same state.

Captured during the 2026-05-13 build session.

---

## Software on the Windows host

| Item | Version | Source (verified) | Installed at | How |
|---|---|---|---|---|
| **MIT Kerberos for Windows** | 4.1 (amd64) | `https://web.mit.edu/kerberos/dist/kfw/4.1/kfw-4.1-amd64.msi` — Authenticode signed by `CN=Massachusetts Institute of Technology, OU=Kerberos Consortium` | `C:\Program Files\MIT\Kerberos\` | `msiexec /i kfw-4.1-amd64.msi /qn /norestart` (elevated). Verified SHA-256 `CDCB7EC4ADDD9716C0E0C74FE0944CB97C83BFEEBC2C267E63E8CAC2AD3DC872` |
| **DBeaver Community Edition** | 26.0.4 | `winget install --id DBeaver.DBeaver.Community -e --silent` (winget source). Underlying package signed by `CN=DBeaver Corp` | `C:\Users\<you>\AppData\Local\DBeaver\` *(per-user install — not Program Files)* | Winget. Direct installer download (`https://dbeaver.io/files/<version>/dbeaver-ce-<version>-x86_64-setup.exe`) was also attempted but the NSIS-style installer returned exit code `666660` under `Start-Process -ArgumentList '/S'`. Winget worked. |
| **Oracle JDBC thin driver (ojdbc8)** | 23.3.0.23.09 | Maven Central: `https://repo1.maven.org/maven2/com/oracle/database/jdbc/ojdbc8/23.3.0.23.09/ojdbc8-23.3.0.23.09.jar` | `C:\Users\<you>\jdbc\oracle\23.3\ojdbc8.jar` | `Invoke-WebRequest`. 6.66 MB. |
| **Oracle PKI library (oraclepki)** | 23.3.0.23.09 | Maven Central: `https://repo1.maven.org/maven2/com/oracle/database/security/oraclepki/23.3.0.23.09/oraclepki-23.3.0.23.09.jar` | `C:\Users\<you>\jdbc\oracle\23.3\oraclepki.jar` | `Invoke-WebRequest`. 470 KB. |
| **Oracle OSDT core (osdt_core)** | 21.9.0.0 | Maven Central: `https://repo1.maven.org/maven2/com/oracle/database/security/osdt_core/21.9.0.0/osdt_core-21.9.0.0.jar` | `C:\Users\<you>\jdbc\oracle\23.3\osdt_core.jar` | `Invoke-WebRequest`. 305 KB. **Note: OSDT and ojdbc8 use independent version trains — osdt's 21.9 is the latest GA and is compatible with ojdbc8 23.x.** |
| **Oracle OSDT cert (osdt_cert)** | 21.9.0.0 | Maven Central: `https://repo1.maven.org/maven2/com/oracle/database/security/osdt_cert/21.9.0.0/osdt_cert-21.9.0.0.jar` | `C:\Users\<you>\jdbc\oracle\23.3\osdt_cert.jar` | `Invoke-WebRequest`. 206 KB. |

### Files staged in the repo

- `config\windows\krb5.ini.example` → copied to `C:\ProgramData\MIT\Kerberos5\krb5.ini`
- `config\windows\dbeaver-jvm-args.example` → injected into `C:\Users\<you>\AppData\Local\DBeaver\dbeaver.ini` under `-vmargs`
- `config\windows\trust\mylab-root-ca.cer` → imported to `Cert:\LocalMachine\Root`
- `config\windows\trust\mylab-root-ca.pem` → pushed to ora01 trust stores

### Environment variables set

| Var | Scope | Value |
|---|---|---|
| `PATH` (prepend) | Machine | `C:\Program Files\MIT\Kerberos\bin` — so `kinit/klist/kvno` resolve to MIT's, not Eclipse Adoptium's bundled ones |
| `KRB5CCNAME` | User | `FILE:C:\Users\<you>\krb5cc` |
| `KRB5CCNAME` | Machine | `FILE:C:\Users\<you>\krb5cc` *(redundant safety belt for shells that don't inherit User-scope vars)* |

### Trust-store changes

- `Cert:\LocalMachine\Root` — imported `mylab-root-ca.cer` (thumbprint `DE70022A87ED4090463D94E388DCADF3EDA4278D`)
- `C:\Windows\System32\drivers\etc\hosts` — appended:
  ```
  192.168.56.10  ad1.mylab.local  ad1
  192.168.56.20  ora01.mylab.local ora01
  ```

### What I noticed about the corporate TLS chain

Both `dbeaver.io` and `repo1.maven.org` are served back to this Windows host via a TLS-intercepting proxy. The cert chain presented to the host is:

```
Subject : CN=<the real site>
Issuer  : CN=SSL-SG1-GLOBAL, OU=Operations, O=Cloud Services, C=US
```

This is a Bluecoat/Symantec corporate inspection proxy. It re-signs every TLS connection with its own intermediate, so the local Windows trust store needs the Bluecoat root for HTTPS to work. That root is already pinned (probably via GPO) — `tableau_ad_oracle\ca\bluecoat-cloud-services-root-ca.crt` is the same root for reference.

**This affects content visibility but not integrity** for our installs: the downloaded MSI/EXE/JAR files retain their original Authenticode/PGP signatures, and we verified those independently of the TLS pipe.

---

## Software on `ora01` (Linux)

Already installed before this session — I just used what was there.

| Item | Version | Path | Notes |
|---|---|---|---|
| Oracle Database | 19c (19.0.0) | `/u01/app/oracle/product/19.0.0/dbhome_1` | CDB `ORCLCDB`; PDB `ORCLPDB1` (READ WRITE). Manually started this session via `lsnrctl start` + `STARTUP`. |
| Oracle 23ai Free | (present, unused) | `/opt/oracle/product/23ai/dbhomeFree` | Not used by this lab. |
| MIT Kerberos | distro default | `/usr/bin/{kinit,klist,kvno}` | `/etc/krb5.conf` already configured for `MYLAB.LOCAL`. |
| sssd + realmd | distro default | — | Host realm-joined to `mylab.local`. |
| Oracle keytab | — | `/etc/oracle/keytabs/ora01.keytab` (0640 oracle:oinstall) | Generated by `ktpass-keytabs.ps1` on `ad1`. Principal `oracle/ora01.mylab.local@MYLAB.LOCAL`, AES256-SHA1. |

### Trust-store additions made this session

| Store | Source file | How |
|---|---|---|
| `/etc/pki/ca-trust/source/anchors/mylab-root-ca.pem` | Pushed via `scp` from `config\windows\trust\mylab-root-ca.pem` | `sudo install -m 0644 ...; sudo update-ca-trust` |
| `$ORACLE_HOME/jdk/jre/lib/security/cacerts` (alias `mylab-root-ca`, default storepass `changeit`) | Same PEM | `keytool -import -trustcacerts -noprompt -alias mylab-root-ca` |

Verification: `openssl s_client -connect ad1.mylab.local:636 -CAfile /etc/pki/tls/certs/ca-bundle.crt` returns `Verify return code: 0 (ok)`.

---

## Software on `ad1` (Windows Server 2022, mylab.local DC)

| Item | Version | Source | Why |
|---|---|---|---|
| **AD Certificate Services role** | Windows Server 2022 built-in | `Install-WindowsFeature AD-Certificate, ADCS-Cert-Authority -IncludeManagementTools` (run via `VBoxManage guestcontrol`) | Needed for LDAPS — DC had no server cert before this session. |
| **Enterprise Root CA `mylab-root-ca`** | created this session, valid 2026-05-13 → 2036-05-13 | `Install-AdcsCertificationAuthority -CAType EnterpriseRootCa -CACommonName 'mylab-root-ca' -CryptoProviderName 'RSA#Microsoft Software Key Storage Provider' -KeyLength 2048 -HashAlgorithmName SHA256 -ValidityPeriod Years -ValidityPeriodUnits 10 -Force` | Signs the DC cert. RSA-2048 / SHA-256. Self-signed. |
| **DC server cert (`CN=ad1.mylab.local`)** | issued by `mylab-root-ca`, valid 2026-05-13 → 2027-05-13 | AD CS auto-enrolled the "Domain Controller" template after `gpupdate /force /target:computer; certutil -pulse` | NTDS picks this up; LDAPS now serves a valid chain. |

The same root CA cert was exported from `Cert:\LocalMachine\My` and committed to this repo at `config\windows\trust\mylab-root-ca.cer` (DER) and `.pem`. Those files are the **canonical** copies — the repo, not the DC, is the source of truth for distributing them to new clients.

### Why the DC certificate was not done via `certreq` / manual CSR

Auto-enrollment via the built-in "Domain Controller" template is the recommended path — it produces a cert with the correct SAN (`ad1.mylab.local`), the correct EKU (Server Authentication), and the right CRL distribution points to satisfy strict-validation TLS clients. A manual CSR-based cert would need each of those configured by hand and would not auto-renew.

---

## Workstation VM `wks01` (added in a later session)

When the corporate-laptop constraint became clear, a dedicated Vagrant-managed Windows VM joined to `mylab.local` was added to remove the daily-`kinit` friction. Details in [13-domain-joined-workstation.md](13-domain-joined-workstation.md); brief record here:

| Item | Source / version | Where it lives | How |
|---|---|---|---|
| Base box | `gusztavvargadr/windows-11` 2601.0.0 (Feb 2026) | Vagrant box cache | `vagrant box add gusztavvargadr/windows-11 --provider virtualbox` (~10 GB download) |
| VM definition | [lab/Vagrantfile](../lab/Vagrantfile) | 192.168.56.40, 3 GB RAM, 2 vCPU, host-only NIC2, NAT NIC1 | `vagrant up wks01` |
| Lab Root CA pinned | `mylab-root-ca.cer` from this repo | `Cert:\LocalMachine\Root` on wks01 | Phase 1 provisioner |
| Corporate proxy CAs pinned | `bluecoat-cloud-services-root-ca.crt` + `symantec-enterprise-mobile-root.crt` from `../tableau_ad_oracle/ca/` | `Cert:\LocalMachine\Root` on wks01 | Phase 1 provisioner. Without these, all HTTPS through the host's MITM-intercepting corp proxy fails on a fresh non-corp-GPO machine. |
| `allowtgtsessionkey=1` | This repo's `config\windows\allowtgtsessionkey.reg` | `HKLM:\SYSTEM\CurrentControlSet\Control\Lsa\Kerberos\Parameters` | Phase 1 provisioner |
| Domain join | `Add-Computer -DomainName mylab.local -Credential MYLAB\Administrator` | Computer name `WKS01` joined to `mylab.local` | Phase 1, password supplied via `$env:AD_ADMIN_PW` on host; never persisted |
| DBeaver Community | 25.3.4 portable zip | `C:\Program Files\dbeaver\` | Phase 2: `Invoke-WebRequest dbeaver.io/files/25.3.4/dbeaver-ce-25.3.4-win32.win32.x86_64.zip` (~123 MB) → `Expand-Archive` |
| Oracle JDBC jars | ojdbc8 23.3.0.23.09, oraclepki 23.3.0.23.09, osdt_core 21.9.0.0, osdt_cert 21.9.0.0 | `C:\Users\Public\jdbc\oracle\23.3\` | Phase 2: Maven Central downloads (same artifacts as on the host's standalone path) |
| `dbeaver.ini` JVM args | Same 4 lines as on the host | `C:\Program Files\dbeaver\dbeaver.ini` | Phase 2 injects under `-vmargs` |
| Desktop shortcut | `C:\Users\Public\Desktop\DBeaver.lnk` | All users see it | Phase 2 creates via `WScript.Shell` |

### Provisioning was not first-try

Documenting the bugs that surfaced so the same scripts work the second time you re-run them:

1. **Non-ASCII characters in scripts.** Em-dashes (`—`) in `Write-Host` strings broke PowerShell parse on the guest because Vagrant's WinRM upload writes the file as Windows ANSI by default. **Fix:** stick to ASCII in `.ps1` files run inside the guest.
2. **`$ErrorActionPreference='Stop'` + `2>&1 |` on native commands.** `reg.exe`/`w32tm.exe` write success messages to stderr; piping `2>&1` then `ForEach-Object` under `Stop` mode escalates that to a terminating error. **Fix:** drop `Stop` globally for the script, wrap each step in `try/catch`, and check `$LASTEXITCODE` explicitly for native commands.
3. **`Add-Computer -NewName` clash on re-provision.** First run renamed the computer to `wks01`; second run's `Add-Computer -NewName wks01` refused with `NewNameIsOldName`. **Fix:** detect current name and pass `-NewName` only when the names actually differ.
4. **ad1 was powered off during one retry.** `Add-Computer` returned the unhelpful error `The specified domain either does not exist or could not be contacted.`. **Fix:** confirm ad1 is running and port 88 is reachable from wks01 (via the host) before trying the join. Newer provision runs wait for ad1's port 88 first with an `until` loop.
5. **Corporate proxy intercepts HTTPS** (Bluecoat/Symantec). Without the corp roots, `Invoke-RestMethod 'https://api.github.com/...'` from wks01 fails `Could not establish trust relationship for the SSL/TLS secure channel.` **Fix:** Vagrantfile uploads the sibling repo's `ca/*.crt` and Phase 1 imports them to `LocalMachine\Root`. Also `[Net.ServicePointManager]::SecurityProtocol = Tls12 -bor Tls13` in Phase 2 so PowerShell 5.1 negotiates the right version.

## What was deliberately NOT installed

- Oracle Instant Client on the Windows host — runbook (chapter 09) treats it as optional; not needed for DBeaver-only flow.
- Vagrant's "insecure" SSH key into `tableau-sim-ora01` — that VM's vagrant user accepts the operator's default OpenSSH key, so we used that path instead.
- Bluecoat / Symantec corporate roots — already present in the host's `LocalMachine\Root` via existing GPO. Confirmed by inspecting the TLS chain to `dbeaver.io` and `repo1.maven.org`.
- A custom Java JRE — DBeaver 26.0.4 ships its own runtime under `<install>\jre\`.

---

## How to re-create from scratch

In order:

1. **VMs:** `vagrant up ora01` from `tableau_ad_oracle\` (`ora01` provisioned via Vagrantfile); start `AD-Server-DC1` via VBoxManage GUI mode.
2. **AD CS on ad1:** RDP in, run the two PowerShell blocks above (or extract them into a script `ad1-install-adcs.ps1`).
3. **Export root CA cert** from `ad1` to `config\windows\trust\mylab-root-ca.{cer,pem}`.
4. **Push to ora01 trust** stores per the table above.
5. **Windows host:**
   ```powershell
   # MIT KfW
   $msi = "$env:TEMP\kfw.msi"
   Invoke-WebRequest 'https://web.mit.edu/kerberos/dist/kfw/4.1/kfw-4.1-amd64.msi' -OutFile $msi
   Start-Process msiexec.exe -ArgumentList "/i `"$msi`" /qn /norestart" -Wait
   # DBeaver
   winget install --id DBeaver.DBeaver.Community -e --accept-package-agreements --accept-source-agreements --silent
   # JDBC jars
   $jdbc = 'C:\Users\<you>\jdbc\oracle\23.3'; New-Item $jdbc -ItemType Directory -Force | Out-Null
   $b = 'https://repo1.maven.org/maven2/com/oracle/database'
   Invoke-WebRequest "$b/jdbc/ojdbc8/23.3.0.23.09/ojdbc8-23.3.0.23.09.jar"        -OutFile "$jdbc\ojdbc8.jar"
   Invoke-WebRequest "$b/security/oraclepki/23.3.0.23.09/oraclepki-23.3.0.23.09.jar" -OutFile "$jdbc\oraclepki.jar"
   Invoke-WebRequest "$b/security/osdt_core/21.9.0.0/osdt_core-21.9.0.0.jar"      -OutFile "$jdbc\osdt_core.jar"
   Invoke-WebRequest "$b/security/osdt_cert/21.9.0.0/osdt_cert-21.9.0.0.jar"      -OutFile "$jdbc\osdt_cert.jar"
   # Trust
   Import-Certificate -FilePath .\config\windows\trust\mylab-root-ca.cer -CertStoreLocation Cert:\LocalMachine\Root
   # Env
   [Environment]::SetEnvironmentVariable('KRB5CCNAME','FILE:C:\Users\<you>\krb5cc','User')
   $p = [Environment]::GetEnvironmentVariable('PATH','Machine')
   [Environment]::SetEnvironmentVariable('PATH', "C:\Program Files\MIT\Kerberos\bin;$p", 'Machine')
   # krb5.ini
   New-Item -ItemType Directory -Force -Path 'C:\ProgramData\MIT\Kerberos5' | Out-Null
   Copy-Item .\config\windows\krb5.ini.example 'C:\ProgramData\MIT\Kerberos5\krb5.ini'
   # hosts
   "192.168.56.10  ad1.mylab.local  ad1`r`n192.168.56.20  ora01.mylab.local ora01" |
       Add-Content 'C:\Windows\System32\drivers\etc\hosts'
   # dbeaver.ini Kerberos JVM args
   # ... see config\windows\dbeaver-jvm-args.example for the four lines to add under -vmargs
   ```
6. **Run** `.\scripts\windows\Invoke-DBeaverPrecheck.ps1` — should produce all-PASS-or-SKIP.

After this, a fresh DBeaver connection profile (chapter 08) plus `kinit alice@MYLAB.LOCAL` is the only remaining step.
