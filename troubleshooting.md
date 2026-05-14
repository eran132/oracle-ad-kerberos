# Troubleshooting

Anchored reference for every error mode the runbook in [docs/09-verification-end-to-end.md](docs/09-verification-end-to-end.md) can hit. Each section starts with the **literal error string** you'll see, lists likely causes, and prescribes a fix.

When debugging, the single most useful thing you can do is flip both `-Dsun.security.krb5.debug=true` and `-Dsun.security.jgss.debug=true` in `dbeaver.ini`, restart DBeaver from a PowerShell window, reproduce the failure, and read the AS-REQ / TGS-REQ / AP-REQ trace.

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

## driver-version-mismatch

**Symptoms:**
- `java.lang.NoSuchMethodError: 'void oracle.net.ns.NSProtocol.<init>(...)'`
- `java.lang.NoSuchFieldError`
- Random JDBC failures only on Kerberos auth (password auth fine).

**Cause:** `ojdbc8.jar` is from one Oracle release, `oraclepki.jar` / `osdt_*.jar` from another. The classes link successfully at load time but blow up when called.

**Fix:** Delete all four jars from the DBeaver driver definition, re-download as a single bundle (`ojdbc8-full.tar.gz` from Oracle's JDBC download page), re-add only those four. See [docs/07-dbeaver-oracle-driver.md](docs/07-dbeaver-oracle-driver.md) section 2.
