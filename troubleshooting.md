# Troubleshooting

Anchored reference for every error mode the runbook in [docs/09-verification-end-to-end.md](docs/09-verification-end-to-end.md) can hit. Each section starts with the **literal error string** you'll see, lists likely causes, and prescribes a fix.

When debugging, the single most useful thing you can do is flip both `-Dsun.security.krb5.debug=true` and `-Dsun.security.jgss.debug=true` in `dbeaver.ini`, restart DBeaver from a PowerShell window, reproduce the failure, and read the AS-REQ / TGS-REQ / AP-REQ trace.

## Quick-jump error index

| Error string | Section |
|---|---|
| `Clock skew too great` / `KRB_AP_ERR_SKEW (37)` | [#clock-skew](#clock-skew) |
| `Cannot resolve servers for KDC` / DNS-related | [#dns-resolution](#dns-resolution) |
| `Server not found in Kerberos database` (KDC_ERR_S_PRINCIPAL_UNKNOWN) | [#kdc-err-s-principal-unknown](#kdc-err-s-principal-unknown) |
| `KRB_AP_ERR_MODIFIED` | [#krb-ap-err-modified](#krb-ap-err-modified) |
| `Encryption type ... is not supported by the server` | [#enctype-mismatch](#enctype-mismatch) |
| `ORA-12631: NO_CRED_RECEIVED` / Username retrieval failed | [#ora-12631](#ora-12631) |
| `ORA-12638: Credential retrieval failed` | [#ora-12638](#ora-12638) |
| `ORA-12641: Authentication service failed to initialize` | [#ora-12641](#ora-12641) |
| `ORA-01017: invalid username/password; logon denied` (when using Kerberos) | [#ora-01017-kerberos-fallback](#ora-01017-kerberos-fallback) |
| `ORA-17430: Must be logged on to the server` | [#ora-17430](#ora-17430) |
| `ORA-18923: No valid credentials provided` / `Connection refused: getsockopt` | [#ora-18923](#ora-18923) |
| `ORA-24247: network access denied by access control list (ACL)` (from `ad_sync` package) | [#ora-24247](#ora-24247) |
| `ORA-28030: Server encountered problems accessing LDAP directory service` | [#ora-28030](#ora-28030) |
| `EncryptionKey: Key bytes cannot be null!` (from JDBC) | [#jdbc-encryptionkey-null](#jdbc-encryptionkey-null) |
| `NoClassDefFoundError: oracle/security/o5logon/...` | [#jdbc-noclassdef-o5login](#jdbc-noclassdef-o5login) |
| `cannot access class sun.security.krb5.internal.APReq ... module does not export` | [#jdbc-module-access](#jdbc-module-access) |
| `GSS-API: Defective token detected` | [#gss-defective-token](#gss-defective-token) |
| `TNS:no listener` / `TNS-12541` | [#tns-12541](#tns-12541) |
| LDAPS-related (handshake fail, chain untrusted) | [#ldaps-no-cert](#ldaps-no-cert), [#ldaps-chain-untrusted](#ldaps-chain-untrusted) |

## Diagnostics matrix — symptom → layer → first command

Start here. Identify the layer before diving into a section; most time is lost debugging the wrong layer.

| Symptom | Likely layer | First diagnostic | Then see |
|---|---|---|---|
| DBeaver shows a **password prompt** at connect | Client never got/used a TGT | `klist` (MIT) and Windows `klist` — is there a `krbtgt/MYLAB.LOCAL` ticket? | [docs/06](docs/06-windows-lsa-and-ccache.md), [#ora-01017-kerberos-fallback](#ora-01017-kerberos-fallback) |
| `ORA-01017: invalid username/password` under Kerberos | DBeaver fell back to password auth | `data-sources.json` `auth-model` (must be `oracle_native`); driver prop `oracle.net.authentication_services=KERBEROS5` (no parens) | [#ora-01017-kerberos-fallback](#ora-01017-kerberos-fallback) |
| `ORA-12638: Credential retrieval failed` | Server-side Kerberos adapter / sqlnet | `sqlnet.ora` on ora01; `klist -kte` keytab readable by `oracle` | [#ora-12638](#ora-12638) |
| `KRB_AP_ERR_MODIFIED` | SPN ↔ keytab key mismatch | `kvno oracle/ora01.mylab.local` vs `klist -kte` KVNO on the keytab | [#krb-ap-err-modified](#krb-ap-err-modified) |
| `KDC_ERR_S_PRINCIPAL_UNKNOWN` | SPN not registered / wrong host string / duplicate | `setspn -Q oracle/ora01.mylab.local`; `setspn -X` | [#kdc-err-s-principal-unknown](#kdc-err-s-principal-unknown), [#duplicate-spn](#duplicate-spn) |
| `KRB_AP_ERR_SKEW` / clock errors | Time | `w32tm /stripchart` (Win) / `chronyc tracking` (ora01) | [#clock-skew](#clock-skew) |
| Intermittent Kerberos failures, no clear error | DNS / reverse DNS | `host <fqdn>` and `host <ip>` must agree | [docs/20 §3](docs/20-architecture-and-hardening.md) |
| JDBC `EncryptionKey: Key bytes cannot be null` | JVM ↔ MIT Kerberos delegation path | `krb5.ini` — is `forwardable = false`? | [#jdbc-encryptionkey-null](#jdbc-encryptionkey-null) |
| `cannot access class sun.security.krb5...` | JVM module access (Java 17+) | `dbeaver.ini` — is the full `--add-opens` set present? | [#jdbc-module-access](#jdbc-module-access) |
| Authenticates fine but **has no privileges / wrong role** | `ad_sync` / LDAP authorization | `SELECT lvl,msg FROM ad_sync.ad_sync_log ORDER BY ts` (look for `ERROR`, rc=49) | [docs/17](docs/17-external-users-and-ad-sync.md) |
| `ORA-24247` from the sync package | Missing network ACL | `SELECT host,principal,privilege FROM dba_host_aces` | [#ora-24247](#ora-24247) |
| `ORA-28030` | CMU enabled and broken (19c) | confirm `LDAP_DIRECTORY_ACCESS` — should be `NONE` for the ad_sync model | [#ora-28030](#ora-28030), [docs/16](docs/16-cmu-19c-failure-mode.md) |
| LDAPS handshake / chain errors | Wallet trust ↔ DC cert | `openssl s_client -connect ad1.mylab.local:636` | [#ldaps-no-cert](#ldaps-no-cert), [#ldaps-chain-untrusted](#ldaps-chain-untrusted) |

---

## clock-skew

**Symptoms:**
- `kinit: Clock skew too great while getting initial credentials`
- `KRB_AP_ERR_SKEW (37)`
- DBeaver Test Connection works first time then fails after the VM has been suspended.

**Cause:** Kerberos rejects requests whose timestamps differ by more than 5 minutes from the KDC's clock. Suspended VirtualBox VMs drift heavily — when you resume `ad1` after lunch, its clock can be hours behind.

**Fix:**
```powershell
# On Windows host
PS> w32tm /stripchart /computer:ad1.mylab.local /samples:3
```
Look for offset >300s. Then:
```powershell
# Force resync inside the DC VM (RDP into ad1, in an elevated cmd):
> w32tm /resync /force
```
For the Oracle VM:
```bash
[ora01]$ sudo chronyc -a makestep
```
After all three (host + DC + ora01) are within 1s of each other, retry `kinit`.

Prevention: disable VirtualBox "Pause VM" for these guests, or run `w32tm /resync` as a guest scheduled task on resume.

---

## dns-resolution

**Symptoms:**
- `kinit: Cannot resolve servers for KDC in realm "MYLAB.LOCAL"`
- `Resolve-DnsName : ad1.mylab.local : DNS name does not exist`
- `Test-NetConnection ora01 -Port 1521` shows `RemoteAddress: (none)`.

**Cause:** Windows host is not pointed at the AD DNS server, and there is no static hosts entry.

**Fix:** Add to `C:\Windows\System32\drivers\etc\hosts` (run notepad as Administrator):
```
192.168.56.10  ad1.mylab.local  ad1
192.168.56.20  ora01.mylab.local ora01
```
Then `ipconfig /flushdns`.

Verify:
```powershell
PS> Resolve-DnsName ad1.mylab.local -Type A
PS> Resolve-DnsName ora01.mylab.local -Type A
```

---

## kdc-err-s-principal-unknown

**Symptoms:**
- `kvno: Server not found in Kerberos database while getting credentials for oracle/ora01.mylab.local@MYLAB.LOCAL`
- JDBC: `KrbException: Server not found in Kerberos database (7)`

**Cause:** The SPN `oracle/ora01.mylab.local` is missing from AD, exists on the wrong account, or has a casing/spelling typo.

**Fix:**
```powershell
# On the DC (or any domain workstation):
> setspn -Q oracle/ora01.mylab.local
# Should return exactly one CN= line under svc-ora01.

> setspn -L svc-ora01
# Should include "oracle/ora01.mylab.local" and "oracle/ora01".
```

If missing, re-run [..\tableau_ad_oracle\scripts\ad-create-lab-accounts.ps1](../tableau_ad_oracle/scripts/ad-create-lab-accounts.ps1), or add manually:
```powershell
> setspn -S "oracle/ora01.mylab.local" svc-ora01
> setspn -S "oracle/ora01"             svc-ora01
```

Common pitfalls:
- SPN is `oracle/ora01.mylab.local` (lower-case host), but DBeaver was asked for `Oracle/...` somehow — Kerberos service-name part is case-sensitive in some clients.
- SPN registered on `svc-tab-deleg` (Tableau service account from the sibling lab) instead of `svc-ora01` — clean up the wrong one first.

See also [#duplicate-spn](#duplicate-spn).

---

## duplicate-spn

**Symptoms:**
- `kvno` returns successfully but DBeaver fails with `KRB_AP_ERR_MODIFIED`.
- `setspn -X` (cross-domain duplicate check) flags `oracle/ora01.mylab.local`.

**Cause:** The same SPN is registered on more than one AD account. The KDC picks one, encrypts the ticket with that account's key; the service (Oracle reading its keytab) is the *other* account and can't decrypt.

**Fix:** Identify both, decide which is correct, remove from the other:
```powershell
> setspn -X
> setspn -D "oracle/ora01.mylab.local" wrong-account
```
Then bump the kvno on the survivor by rotating the password / re-running `ktpass`, so old service tickets are invalidated. Re-deploy the new keytab to `/etc/oracle/keytabs/ora01.keytab` on `ora01`.

---

## krb-ap-err-modified

**Symptoms:**
- JDBC: `KrbException: Identifier doesn't match expected value (906)` *(historically labeled MODIFIED)*
- `kvno` works on Windows but the same ticket fails when presented to Oracle.

**Cause:** Mismatch between the key in the keytab (server side) and the current key in AD (KDC side). Happens when:
- `svc-ora01` password was changed in AD without regenerating the keytab.
- `ktpass` was run with a different `-pass` value than what AD has stored.
- The keytab was regenerated but never copied to `ora01`.

**Fix:** Re-issue keytab so AD and keytab agree:
```powershell
# On the DC:
PS> .\..\tableau_ad_oracle\scripts\ktpass-keytabs.ps1
# Note: this resets svc-ora01's password to the one in the script's secret.
PS> scp .\out\ora01.keytab vagrant@ora01.mylab.local:/tmp/
```
```bash
# On ora01:
[ora01]$ sudo cp /tmp/ora01.keytab /etc/oracle/keytabs/ora01.keytab
[ora01]$ sudo chown oracle:oinstall /etc/oracle/keytabs/ora01.keytab
[ora01]$ sudo chmod 0640 /etc/oracle/keytabs/ora01.keytab
[ora01]$ sudo -u oracle klist -kte /etc/oracle/keytabs/ora01.keytab
# Verify the kvno matches what `kvno oracle/...` reports on Windows.
```

Then on the Windows host: `kdestroy; kinit alice@MYLAB.LOCAL; kvno oracle/...` and retry DBeaver.

---

## enctype-mismatch

**Symptoms:**
- `kvno: KDC has no support for encryption type while getting credentials for oracle/ora01.mylab.local`
- JDBC: `KrbException: Encryption type AES256 CTS mode with HMAC SHA1-96 is not supported by the server`

**Cause:** The `msDS-SupportedEncryptionTypes` attribute on `svc-ora01` does not include AES, but the keytab was generated with `-crypto AES256-SHA1`. Default AD UPN account behavior in 2008+ functional levels disables AES unless explicitly enabled.

**Fix:** On the DC, in PowerShell as a Domain Admin:
```powershell
> Set-ADUser svc-ora01 -KerberosEncryptionType AES256
# Or explicitly via bitmask:
> Set-ADUser svc-ora01 -Replace @{ "msDS-SupportedEncryptionTypes" = 0x18 }
# 0x10 = AES256, 0x08 = AES128. 0x18 enables both.
```
Then **reset the password** so a new key is generated using the new enctype:
```powershell
> Set-ADAccountPassword svc-ora01 -Reset
> .\..\tableau_ad_oracle\scripts\ktpass-keytabs.ps1   # regen keytab
```
Redeploy keytab to `ora01` (see [#krb-ap-err-modified](#krb-ap-err-modified)).

Confirm with `Test-SpnLookup.ps1` (`AES256Bit` should be `True`).

---

## ora-12631

**Symptoms:**
- `ORA-12631: NO_CRED_RECEIVED`
- DBeaver dialog: "ORA-12631: Username retrieval failed".

**Cause:** Oracle expected a Kerberos credential from the client but the client didn't send one. Either:
1. The client's `sqlnet.ora` (or driver property) doesn't have `KERBEROS5` in `AUTHENTICATION_SERVICES`.
2. The credential cache the client looked at was empty.
3. JVM has `useSubjectCredsOnly=true` (default) and no JAAS Subject is set.

**Fix:**
- DBeaver: re-check **Driver properties** has `oracle.net.authentication_services` = `(KERBEROS5)` (parentheses required). See [docs/08-dbeaver-connection.md#3-driver-properties-tab](docs/08-dbeaver-connection.md).
- `dbeaver.ini` has `-Djavax.security.auth.useSubjectCredsOnly=false`.
- `klist` shows a valid TGT in the cache pointed at by `KRB5CCNAME`.

See also [#ora-12638](#ora-12638).

---

## ora-12638

**Symptoms:**
- `ORA-12638: Credential retrieval failed`
- JDBC stack includes `LoginException: Unable to obtain Principal Name for authentication`.

**Cause:** The JVM looked for credentials and found none, OR `KRB5CCNAME` is set in your shell but **not in DBeaver's process environment**.

**Fix:**
1. Confirm `KRB5CCNAME` is set at User scope:
   ```powershell
   PS> [Environment]::GetEnvironmentVariable("KRB5CCNAME", "User")
   FILE:C:\Users\<you>\krb5cc
   ```
2. Close **all** DBeaver windows (and the launcher) — Windows applies env vars at process spawn only.
3. Reopen DBeaver from a **new** Start Menu / Explorer click (NOT from an old taskbar instance — that may inherit the old environment).
4. Run `Test-Connection` again.

Alternative quick test: launch DBeaver from PowerShell, which forwards the current env:
```powershell
PS> $env:KRB5CCNAME = "FILE:C:\Users\<you>\krb5cc"
PS> & "C:\Program Files\DBeaver\dbeaver.exe"
```

---

## gss-defective-token

**Symptoms:**
- `GSSException: Defective token detected (Mechanism level: GSSHeader did not find the right tag)`
- DBeaver: "GSS-API: Defective token detected".

**Cause:** The token Oracle returned isn't parseable by the JVM's GSSAPI. Almost always one of:
1. **Realm case** mismatch. `krb5.ini` says `default_realm = mylab.local` (lower-case) but AD only knows `MYLAB.LOCAL`. The client builds a principal `alice@mylab.local`, AD has no record of it under that exact string.
2. **Wrong krb5.ini path** in `-Djava.security.krb5.conf` — JVM uses an empty default config and fails to encrypt the AP-REQ correctly.
3. **`useSubjectCredsOnly=true`** with no Subject configured — JGSS sends a degenerate token.

**Fix:**
1. Open `C:\ProgramData\MIT\Kerberos5\krb5.ini`. Every occurrence of the realm name must be **upper-case** `MYLAB.LOCAL`. The `[domain_realm]` mapping keys (`.mylab.local`, `mylab.local`) stay lower-case — they map DNS suffixes (case-insensitive) to realms (case-sensitive).
2. Confirm `dbeaver.ini` has the right path:
   ```
   -Djava.security.krb5.conf=C:\ProgramData\MIT\Kerberos5\krb5.ini
   ```
3. Confirm `-Djavax.security.auth.useSubjectCredsOnly=false`.

---

## allowtgtsessionkey

**Symptoms:** *(Only relevant if you chose the LSA-cache path in [docs/06](docs/06-windows-lsa-and-ccache.md), section 3.)*
- DBeaver connects, but the JVM debug trace shows `Credentials cache: API:Initial default ccache` with no entries.
- `klist` shows tickets, but the JVM can't see them.

**Cause:** Windows hides the TGT session key from user-mode processes by default. Without the registry tweak, JGSS cannot read the cached TGT even when the user holds one.

**Fix:**
```powershell
PS> reg import .\config\windows\allowtgtsessionkey.reg
PS> Restart-Computer
```
After reboot, `klist` (Windows native) and `klist tickets` will show the same entries the JVM sees. If you don't want to reboot, switch to file-ccache mode (chapter [06](docs/06-windows-lsa-and-ccache.md), section 2).

---

## jdbc-noclassdef-o5login

**Symptoms:**
- DBeaver: `java.lang.NoClassDefFoundError: oracle/security/o5logon/O5LoginClientHelper`
- Connection fails before any network traffic.

**Cause:** `oraclepki.jar` (and/or `osdt_core.jar`, `osdt_cert.jar`) is missing from the DBeaver driver definition. Bundled `ojdbc8.jar` alone is insufficient for Kerberos.

**Fix:** Add the three companion jars in **Database menu → Driver Manager → Oracle → Edit → Libraries**. See [docs/07-dbeaver-oracle-driver.md](docs/07-dbeaver-oracle-driver.md) section 3. The jars MUST come from the same Oracle JDBC release as `ojdbc8.jar`.

---

## ldaps-no-cert

**Symptoms:**
- `Test-KerberosPrereqs.ps1` reports `LdapsPort636 = True` but `LdapsHandshake = False`.
- Error string contains `An existing connection was forcibly closed by the remote host` during `AuthenticateAsClient`.
- `openssl s_client -connect ad1.mylab.local:636` reports `no peer certificate available` / `SSL handshake failure`.

**Cause:** NTDS on the DC has no Server Authentication certificate in `LocalMachine\My`. The TCP port is listening but the TLS stack has nothing to present, so it resets the connection mid-handshake. Common after a fresh DC promotion, after AD CS was uninstalled, or if the DC cert has expired and AD CS auto-enrollment is broken.

**Fix:** On the DC, ensure AD CS is installed and the DC has auto-enrolled a Server Authentication cert. The full procedure is in [docs/11-ldaps-cert-trust.md](docs/11-ldaps-cert-trust.md). Quick path:
```powershell
# Verify cert presence
> Get-ChildItem Cert:\LocalMachine\My | Where-Object {
    ($_.Extensions | Where-Object { $_.Oid.FriendlyName -eq 'Enhanced Key Usage' }).Format($false) -match '1.3.6.1.5.5.7.3.1'
}
# Force enrollment if missing
> gpupdate /force /target:computer
> certutil -pulse
> Restart-Service NTDS -Force
```

## ldaps-chain-untrusted

**Symptoms:**
- `LdapsHandshake = True` but `LdapsChainValid = False`.
- `LdapsChainError` includes `RemoteCertificateChainErrors`, `UntrustedRoot`, or `PartialChain`.
- DBeaver SQL editor works fine (Kerberos doesn't care), but `Test-SpnLookup` / `Get-ADUser` via LDAPS fail.

**Cause:** The DC cert chains to `mylab-root-ca`, but this Windows host does not have the Root CA pinned in `Cert:\LocalMachine\Root`. Strict TLS validation rejects the chain.

**Fix:**
```powershell
PS> Import-Certificate `
        -FilePath .\config\windows\trust\mylab-root-ca.cer `
        -CertStoreLocation Cert:\LocalMachine\Root
```
Then re-run `.\scripts\windows\Invoke-DBeaverPrecheck.ps1`. The `LdapsChainValid` field should flip to `True`. If the trust file is missing, re-export from the DC per [docs/11-ldaps-cert-trust.md](docs/11-ldaps-cert-trust.md) section "How the chain got built".

For ora01-side trust failures (sssd / openssl), see [docs/11](docs/11-ldaps-cert-trust.md) section "Pinning the Root CA on each client" → "ora01 — system trust".

## ora-01017-kerberos-fallback

**Symptoms:**
- `ORA-01017: invalid username/password; logon denied`
- Connection profile has username and password **blank** (intentional, for Kerberos)
- Stack trace shows `T4CConnection.authenticateWithPassword(...)` — driver is doing **password auth**, not Kerberos

**Cause:** DBeaver's connection profile has `auth-model: oracle_os` (the "OS Authentication" option in the Authentication dropdown). With no OS-bound credentials present, the driver silently falls through to password auth with empty creds, hence ORA-01017. The `oracle.net.authentication_services=KERBEROS5` driver property is never given a chance to run.

**Fix:** Right-click the connection → **Edit Connection** → Main tab. Set **Authentication** to **Database Native** (not "OS Authentication"). On disk that means changing the `data-sources.json` entry:
```json
"auth-model": "native"     // was: "oracle_os"
```

A secondary gotcha: if `oracle.net.authentication_services` is set to **`(KERBEROS5)`** (with parens), the JDBC driver may not recognize it and silently skip Kerberos. Use **`KERBEROS5`** without parens for JDBC driver properties. (Parens are sqlnet.ora syntax — not the same parser.)

## ora-17430

**Symptoms:**
- `ORA-17430: Must be logged on to the server`
- Stack trace ends in `assertLoggedOn`, `getVersionNumber`, `getUserName`
- Appears as the *second* error after an upstream auth failure

**Cause:** The JDBC driver did not authenticate, but a subsequent operation (often DBeaver introspecting the database after a failed `Test Connection`) tried to use the half-built `Connection` object. The `assertLoggedOn` check fires because no logon ever completed. This is a **wrapper / cascade** error, not the real failure.

**Fix:** Find the actual upstream error. Look earlier in the DBeaver log (`%APPDATA%\DBeaverData\workspace6\.metadata\.log`) for the **first** error in the cascade — typically `ORA-01017` ([#ora-01017-kerberos-fallback](#ora-01017-kerberos-fallback)), `ORA-12631` ([#ora-12631](#ora-12631)), or a JDBC-layer Kerberos exception. Fix that one; this one disappears.

## ora-18923

**Symptoms:**
- `ORA-18923: The service in process is not supported: No valid credentials provided`
- `(Mechanism level: Connection refused: getsockopt)` or `(Mechanism level: Server not found in Kerberos database)`
- Stack trace mentions `oracle.net.ano.AuthenticationService` doing GSSAPI exchange

**Cause:** The JDBC driver did try Kerberos correctly, but the **KDC was unreachable** when the client tried to fetch a service ticket (TGS-REQ). Common reasons:
- `ad1` is shut down or rebooting
- AD DS service is still starting up after a fresh ad1 boot (port 88 doesn't accept yet)
- VirtualBox host-only network is down on the client side
- Firewall on `ad1` reset to "Public" profile blocking port 88

**Fix:**
```powershell
# From the host (or wks01):
Test-NetConnection 192.168.56.10 -Port 88
Test-NetConnection 192.168.56.10 -Port 464
Test-NetConnection 192.168.56.10 -Port 636
```
All three should return `TcpTestSucceeded: True`. If not:
- Start ad1: `VBoxManage startvm AD-Server-DC1 --type gui`
- Wait 30–60 sec for AD services to bind
- Verify `Get-NetConnectionProfile` on ad1 shows the host-only NIC as `Private` or `DomainAuthenticated`, not `Public` (re-set with `Set-NetConnectionProfile -InterfaceIndex N -NetworkCategory Private`)

Retry once port 88 accepts. This error is **transient** — auth completes once the KDC is reachable. No client-side changes needed.

## jdbc-encryptionkey-null

**Symptoms:**
- `java.lang.IllegalArgumentException: EncryptionKey: Key bytes cannot be null!`
- Stack trace: `EncryptionKey.<init>` → `oracle.net.ano.AuthenticationService.getKRBCredForDelegation(...)` → `AuthenticationService.run` (called via `Subject.doAs`)

**Cause:** Oracle's `AuthenticationService` tries to extract **delegated credentials** from alice's TGT (to support proxy/forward scenarios) every time it's configured for Kerberos. When the JVM's Kerberos cache reader returns `null` for the session-key field — which happens with several combinations of (Java 17/21 + MIT KfW file ccache, Windows LSA cache, AES256 enctype) — `EncryptionKey`'s constructor rejects the null bytes.

**Fix:** Disable mutual authentication in the connection's driver properties so delegation-cred extraction is skipped:
```json
"oracle.net.kerberos5_mutual_authentication": "false"
```

DBeaver path: Edit Connection → Driver properties tab → set `oracle.net.kerberos5_mutual_authentication` to `false`.

Other things to try if disabling mutual auth alone doesn't fix it:
- Add explicit driver properties so ojdbc reads the ccache directly (bypasses JVM's JAAS path):
  ```json
  "oracle.net.kerberos5_cc_name": "C:/Users/<you>/krb5cc",
  "oracle.net.kerberos5_conf":    "C:/ProgramData/MIT/Kerberos5/krb5.ini"
  ```
  Note **forward slashes** in the paths — Oracle's property parser doesn't reliably escape backslashes.
- Re-`kinit` with a forwardable TGT (`kinit -f alice@MYLAB.LOCAL`). Without `forwardable`, the session-key field may legitimately be absent.

## jdbc-module-access

**Symptoms:**
- `class oracle.net.ano.AuthenticationService (in unnamed module ...) cannot access class sun.security.krb5.internal.APReq (in module java.security.jgss) because module java.security.jgss does not export sun.security.krb5.internal to unnamed module ...`

**Cause:** Java 9+ modular system. Oracle's JDBC needs to reach into Sun's internal Kerberos packages (`sun.security.krb5.internal{,.crypto,.ccache}`) to construct AP-REQ tokens. By default these packages are **not exported** to unnamed modules (which is what jars on the classpath are).

**Fix:** Add these `--add-opens` lines under `-vmargs` in `dbeaver.ini`:
```
--add-opens=java.security.jgss/sun.security.krb5.internal=ALL-UNNAMED
--add-opens=java.security.jgss/sun.security.krb5.internal.crypto=ALL-UNNAMED
--add-opens=java.security.jgss/sun.security.krb5.internal.ccache=ALL-UNNAMED
```
Plus the two DBeaver normally ships:
```
--add-opens=java.security.jgss/sun.security.jgss=ALL-UNNAMED
--add-opens=java.security.jgss/sun.security.krb5=ALL-UNNAMED
```
Restart DBeaver (fully close all windows first — JVM args only re-read at startup).

## tns-12541

**Symptoms:**
- `ORA-12541: TNS:no listener` from the client
- `Test-NetConnection ora01 -Port 1521` returns `TcpTestSucceeded: False`

**Cause:** The Oracle listener on `ora01` isn't running, or the database instance isn't registered with the listener.

**Fix:** On `ora01` as the oracle user:
```bash
[ora01]$ lsnrctl status   # if nothing, then:
[ora01]$ lsnrctl start

# And the database:
[ora01]$ export ORACLE_SID=ORCLCDB
[ora01]$ sqlplus -S / as sysdba <<<'STARTUP; ALTER PLUGGABLE DATABASE ALL OPEN; EXIT;'
[ora01]$ sleep 30 ; lsnrctl status   # services should now list orclpdb1
```

Common triggers for the listener+DB being down:
- ora01 was restarted (no autostart configured by default in this lab)
- The wall-clock jumped (e.g. NTP step); Oracle is sensitive to large time changes
- Memory pressure on the host VirtualBox killed the instance

## ora-12641

**Symptoms:**
- `ORA-12641: Authentication service failed to initialize`
- Found in `$ORACLE_HOME/network/log/sqlnet.log` or the client trace
- Often triggered by `sqlplus /@TNS` from Linux

**Cause:** Client-side sqlnet couldn't initialize the Kerberos authentication adapter. Most common reason in this lab: `SQLNET.KERBEROS5_CC_NAME = /tmp/krb5cc_%{uid}` was set, but Oracle's sqlnet parser **does not substitute `%{uid}`** (that's a libkrb5 / sssd syntax, not an Oracle one). The result: sqlnet looks for a file literally named `/tmp/krb5cc_%{uid}` and can't find it.

**Fix:** Remove the `SQLNET.KERBEROS5_CC_NAME` line from `$ORACLE_HOME/network/admin/sqlnet.ora` entirely. Sqlnet will then fall back to the `KRB5CCNAME` environment variable (or the default `/tmp/krb5cc_$(id -u)`), which is what you want.

Other causes of ORA-12641:
- `/etc/krb5.conf` missing or syntactically invalid
- Keytab path in `SQLNET.KERBEROS5_KEYTAB` unreadable by the running OS user
- Listener restarted while sqlnet.ora was being edited

## driver-version-mismatch

**Symptoms:**
- `java.lang.NoSuchMethodError: 'void oracle.net.ns.NSProtocol.<init>(...)'`
- `java.lang.NoSuchFieldError`
- Random JDBC failures only on Kerberos auth (password auth fine).

**Cause:** `ojdbc8.jar` is from one Oracle release, `oraclepki.jar` / `osdt_*.jar` from another. The classes link successfully at load time but blow up when called.

**Fix:** Delete all four jars from the DBeaver driver definition, re-download as a single bundle (`ojdbc8-full.tar.gz` from Oracle's JDBC download page), re-add only those four. See [docs/07-dbeaver-oracle-driver.md](docs/07-dbeaver-oracle-driver.md) section 2.

## ora-24247

**Symptoms:**
- From the `AD_SYNC.AD_SYNC` package only: `ORA-24247: network access denied by access control list (ACL)`
- Backtrace points at `SYS.DBMS_LDAP_API_FFI` line 25, then `SYS.DBMS_LDAP` `init`, then `AD_SYNC.AD_SYNC`.

**Cause:** From Oracle 12c onward, any PL/SQL package that opens an outbound network connection (DBMS_LDAP, UTL_HTTP, UTL_TCP, UTL_SMTP, …) needs an explicit ACL grant for the target host. The `AD_SYNC` package was created but no ACL was set for it on `ad1.mylab.local`.

**Fix:** Run in the PDB as `SYS`:

```sql
BEGIN
  DBMS_NETWORK_ACL_ADMIN.append_host_ace(
    host => 'ad1.mylab.local',
    ace  => xs$ace_type(
              privilege_list => xs$name_list('connect','resolve'),
              principal_name => 'AD_SYNC',
              principal_type => xs_acl.ptype_db));
END;
/
COMMIT;
```

Verify with `SELECT host, principal, privilege FROM DBA_HOST_ACES WHERE principal='AD_SYNC';` — expect rows for `connect` and `resolve`. Re-run the sync to confirm it now reaches AD. This grant is already in [scripts/oracle/ad-sync-install.sql](scripts/oracle/ad-sync-install.sql); the error usually means that script wasn't run, or was run before the `AD_SYNC` user existed.

## ora-28030

**Symptoms:**
- `ORA-28030: Server encountered problems accessing LDAP directory service`
- DBeaver dialog shows nothing more; SQL*Plus client message ends there.
- Server-side `sqlnet.ora` trace (`TRACE_LEVEL_SERVER = SUPPORT`) shows the wallet read followed by ~1 second silence, then the error packet.
- `tcpdump host <DC> and port 636` shows at most a single TCP connect→FIN with **no TLS Client Hello sent**.

**Cause:** Oracle Centrally Managed Users (CMU) was enabled (`LDAP_DIRECTORY_ACCESS=PASSWORD` set) and the database attempted but failed to bind to AD. On **19c with Kerberos-authenticated CMU users**, this is a confirmed-broken code path — see [docs/16-cmu-19c-failure-mode.md](docs/16-cmu-19c-failure-mode.md) for the full investigation. Oracle's internal NTZ (TLS) layer closes the TCP socket ~7 ms after establishing it, before any TLS handshake, regardless of: wallet entry names (`ORACLE.SECURITY.*` vs `orclextldap*`), `LDAP_DIRECTORY_SYSAUTH` value, `dsi.ora` vs `ldap.ora` config file, SSL version forcing, or SELinux/firewall posture.

**Working alternative shipped by this lab:** [docs/17-external-users-and-ad-sync.md](docs/17-external-users-and-ad-sync.md) — disable CMU (`LDAP_DIRECTORY_ACCESS=NONE`) and use the `AD_SYNC` PL/SQL package + `AFTER LOGON` trigger instead. Same end behavior for users (Kerberos auth + AD-group-driven roles), without the broken CMU code path.

**Fix to make ORA-28030 stop, if you cannot/will not switch off CMU:**
1. Confirm the failure mode by running `DBMS_LDAP.open_ssl(...)` + `simple_bind_s(...)` from PL/SQL against the same wallet — if that succeeds (rc=0 for both), the wallet/cert/network/AD-account path is good and you are definitely hitting the 19c CMU bug.
2. Open an Oracle Support SR with: an `orasrv_*.trc` SQL*Net server trace at level SUPPORT showing the wallet read followed by silence; a `tcpdump` pcap showing the TCP-without-TLS pattern; and the `DBMS_LDAP` PL/SQL test showing the same path works at the protocol level. The bug is internal to `ntz`/`kzn` and not surfaceable by user-mode trace flags.
3. While waiting for Oracle Support, install the `ad_sync` workaround in this repo so users can connect today: `sqlplus / as sysdba @scripts/oracle/ad-sync-install.sql`.
