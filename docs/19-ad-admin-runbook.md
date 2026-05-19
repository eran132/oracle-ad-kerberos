# 19 · AD-side runbook — what the directory administrator does

> Audience: the Windows / AD operations team in the corporate environment. The Oracle DBA hands them this chapter.
>
> Scope: every change that must happen **inside Active Directory** to enable Kerberos authentication and AD-driven authorization for an Oracle 19c database. The Oracle-side configuration is in [RECIPE.md](../RECIPE.md).

All examples use the lab placeholders:

| Placeholder | Substitute with your value |
|---|---|
| `MYLAB.LOCAL` / `mylab.local` | Your AD realm / DNS domain |
| `ad1.mylab.local` | Your Domain Controller's FQDN |
| `ora01.mylab.local` | The Oracle database server's FQDN (must be DNS-resolvable from clients) |
| `oracle/ora01.mylab.local@MYLAB.LOCAL` | The Oracle service principal name |
| `svc-ora01` | The AD service account that owns the Oracle SPN |
| `svc-ora-ldap` | The AD service account the database uses to bind to AD over LDAPS for group lookups |
| `oracle-readers`, `oracle-writers` | AD security groups whose members get specific Oracle roles |
| `<svc-account password>` | The password each AD service account is created with. Comes from your password vault. **Never hard-coded in this repo or in a public ticket.** |

**Run all PowerShell commands on a Domain Controller as a Domain Admin** (or remoting in via `Enter-PSSession`). The `RSAT-AD-PowerShell` feature must be present (`Install-WindowsFeature RSAT-AD-PowerShell` if not).

---

## Quick reference — the four AD objects this setup needs

| # | Object | Type | Lives in | Purpose |
|---|---|---|---|---|
| 1 | `svc-ora01` | User (service) | `CN=Users,DC=mylab,DC=local` | Holds the Oracle SPN `oracle/ora01.mylab.local`. Its long-term key becomes the keytab on the database server. **No human ever logs in as this account.** |
| 2 | `svc-ora-ldap` | User (service) | `CN=Users,DC=mylab,DC=local` | The database binds to AD with this account's UPN + password over LDAPS to look up group membership. **No human ever logs in as this account.** |
| 3 | `oracle-readers` | Security Group, Global | `OU=Groups,DC=mylab,DC=local` | Members get `ORA_READERS_ROLE` in the database. |
| 4 | `oracle-writers` | Security Group, Global | `OU=Groups,DC=mylab,DC=local` | Members get `ORA_WRITERS_ROLE` in the database. |

Plus existing infrastructure that should already be present in a typical corporate AD:
- A working **AD Certificate Services Enterprise CA**, with the Root CA cert trusted by the DC (auto-enrolled DC cert is what makes LDAPS-636 work).
- DNS A-records for the DC(s) and the Oracle host.
- AES-256 enabled domain-wide (default since Server 2008 R2; verify with `Get-ADDomain | Select-Object -Expand AllowedDNSSuffixes` is not relevant; check `Get-ADUser <svcacct> -Properties msDS-SupportedEncryptionTypes`).

---

## Part A — Initial setup (one-time per Oracle database)

### A1. Create the SPN service account `svc-ora01`

The password set here is a **throwaway placeholder** — AD won't create an *enabled* account with no password, but `ktpass` in A2 immediately resets it to the value that actually counts. Don't bother recording this one.

```powershell
# Idempotent: skip creation if the account already exists (rebuild / re-run safe).
$throwaway = ConvertTo-SecureString ([guid]::NewGuid().ToString() + 'Aa1!') -AsPlainText -Force
if (Get-ADUser -Filter "SamAccountName -eq 'svc-ora01'" -ErrorAction SilentlyContinue) {
  Write-Host "svc-ora01 already exists — normalizing its state instead of creating."
  Enable-ADAccount -Identity svc-ora01
  Set-ADUser -Identity svc-ora01 `
    -UserPrincipalName "svc-ora01@MYLAB.LOCAL" `
    -PasswordNeverExpires $true -CannotChangePassword $true
} else {
  New-ADUser `
    -Name "svc-ora01" `
    -SamAccountName "svc-ora01" `
    -UserPrincipalName "svc-ora01@MYLAB.LOCAL" `
    -DisplayName "Oracle Kerberos SPN service (ora01)" `
    -Description "Holds SPN oracle/ora01.mylab.local. Keytab on ora01:/etc/oracle/keytabs/" `
    -AccountPassword $throwaway `
    -Enabled $true `
    -PasswordNeverExpires $true `
    -CannotChangePassword $true `
    -Path "CN=Users,DC=mylab,DC=local"
}

# Enable AES-256 only (RC4 disabled). Bitmask 0x10 = AES256-CTS-HMAC-SHA1-96.
Set-ADUser -Identity svc-ora01 -KerberosEncryptionType "AES256"
```

> `PasswordNeverExpires` is intentional — `ktpass` rotation cycles are deliberate, and an unattended expiry would break Oracle Kerberos auth lab-wide. If your policy forbids this, schedule the keytab rotation (Part B2) to track the password policy.

### A2. Register the Oracle SPN and generate the keytab

`ktpass.exe` does both in one shot. **It always resets the account password and bumps the KVNO** — that is inherent to how it derives the Kerberos key written into the keytab. The throwaway password from A1 is now irrelevant; the value you supply here is the **authoritative** one. **Record it in your password vault** — the next keytab rotation needs the account and keytab to agree again.

Use `-pass *` so `ktpass` prompts interactively: the password never lands in the command line, console history, or process list.

```powershell
# Run on the DC. The keytab is written to .\ora01.keytab in the current dir.
# -pass *  => ktpass prompts (hidden). This is the password that COUNTS;
#             store it in the password vault.
ktpass `
  -princ oracle/ora01.mylab.local@MYLAB.LOCAL `
  -mapuser MYLAB\svc-ora01 `
  -pass * `
  -crypto AES256-SHA1 `
  -ptype KRB5_NT_PRINCIPAL `
  -out .\ora01.keytab
```

#### The two `ktpass` flags people get wrong

| Flag | What it does | Why this value |
|---|---|---|
| `-crypto AES256-SHA1` | Which Kerberos enctype(s) `ktpass` derives into the keytab. `AES256-SHA1` = **AES256-CTS-HMAC-SHA1-96**, Kerberos etype **18**. Other accepted values: `DES-CBC-CRC`/`DES-CBC-MD5` (legacy, broken), `RC4-HMAC-NT` (etype 23, weak/deprecated), `AES128-SHA1` (etype 17), `All` (every enctype incl. weak ones). | The keytab enctype must intersect with **(a)** the account's `msDS-SupportedEncryptionTypes` (we pin AES256 in A1), **(b)** Oracle's `sqlnet.ora`, **(c)** the client `krb5.ini` `default_tkt_enctypes`. Mismatch → `KDC has no support for encryption type` or a `KRB_AP_ERR_MODIFIED`-class failure. `All` would silently ship a weak RC4 key in the keytab — don't. |
| `-ptype KRB5_NT_PRINCIPAL` | The principal **name-type** stamped into the mapping/keytab. `KRB5_NT_PRINCIPAL` = name-type **1**, a standards-compliant general principal. Other values: `KRB5_NT_SRV_INST`/`KRB5_NT_SRV_HST` (Windows host/service-instance types), `KRB5_NT_UNKNOWN` (0). | Oracle's Kerberos adapter and MIT/Heimdal krb5 expect the SPN as a plain principal. With `KRB5_NT_SRV_HST`/`UNKNOWN` the name-type the KDC stamps into the service ticket can fail to match what Oracle's GSSAPI matches against → auth fails even when everything else is correct. `KRB5_NT_PRINCIPAL` is the documented choice for non-Windows (Oracle/Java) interop. |

In one sentence: *"derive an AES256-only keytab for this SPN, named as a standard Kerberos principal so a Linux/Java service can consume it."*

#### References & tool provenance (important nuance)

`ktpass` is a **Microsoft** tool, not an Oracle one — there is no "Oracle docs for ktpass" because Oracle's own Kerberos chapter doesn't use it:

- **`ktpass` flag spec (authoritative):** Microsoft Learn — *ktpass* command reference: <https://learn.microsoft.com/en-us/windows-server/administration/windows-commands/ktpass>. This is the source of truth for `-crypto`, `-ptype`, `-mapuser`, `-pass`. It explicitly states *"Because the default settings are based on older MIT versions, you should always use the `/crypto` parameter"* (corroborating why we pin `AES256-SHA1`) and lists `KRB5_NT_PRINCIPAL` as the recommended type. Note `ktpass` accepts both `/flag` and `-flag` forms; this runbook uses `-flag`.
- **Why we use `ktpass` at all:** because the KDC here is **Active Directory**. Oracle's AD-specific guidance is the 19c *Database Security Guide* → *Configuring Centrally Managed Users with Microsoft Active Directory*: <https://docs.oracle.com/en/database/oracle/oracle-database/19/dbseg/integrating_mads_with_oracle_database.html>
- **Oracle's generic Kerberos chapter** (19c *Database Security Guide* ch. 22, *Configuring Kerberos Authentication*: <https://docs.oracle.com/en/database/oracle/oracle-database/19/dbseg/configuring-kerberos-authentication.html>) deliberately uses **`ktadd`** (MIT `kadmin`) or Oracle's **`okcreate`** — *not* `ktpass`. Those apply when the KDC is MIT/Heimdal, not AD. If anyone asks "the Oracle docs say `okcreate`, why does this runbook say `ktpass`?": because our KDC is AD, and on AD the keytab is produced on the DC with the Windows tool.

#### Verify the keytab really is AES256 (don't trust, check)

`ktpass` historically had AES interop / salt / case quirks, and `Set-ADUser -KerberosEncryptionType AES256` does **not** by itself guarantee RC4 is refused at runtime unless domain policy agrees. Verify both ends:

```powershell
# 1. The account permits ONLY AES256 (bitmask 0x10 = 16; AES128=0x08, RC4=0x04, both AES=0x18=24).
Get-ADUser svc-ora01 -Properties msDS-SupportedEncryptionTypes |
  Select-Object msDS-SupportedEncryptionTypes      # expect 16

# 2. The keytab actually carries etype 18 (AES256-CTS-HMAC-SHA1-96), not 23 (RC4).
ktab.exe -l -e -t -k .\ora01.keytab                # Windows
#   or on ora01:  sudo -u oracle klist -kte /etc/oracle/keytabs/ora01.keytab
```

If the account shows `0` (unset) AD may still hand out RC4 at runtime; explicitly set `16` and confirm the keytab line says `aes256-cts-hmac-sha1-96`. If you ever need RC4 temporarily for debugging, that's the *only* time to widen the bitmask — revert immediately after.

#### SPN must match exactly what JDBC clients connect to

The SPN is `oracle/ora01.mylab.local`. Clients building a Kerberos service ticket derive the SPN from the **host string in their connect descriptor**. If anyone later connects via a CNAME, short name, or load-balancer DNS (`ora01`, `db-prod`, `oracle-vip.mylab.local`) the client asks the KDC for `oracle/<that-name>` — which doesn't exist → `KDC_ERR_S_PRINCIPAL_UNKNOWN`, with no obvious clue. Rules:

- Pick one canonical FQDN, register the SPN for exactly that, and make every client connect string use it verbatim.
- If aliases are genuinely required, add an SPN per alias (`setspn -S oracle/<alias> svc-ora01`) — and re-emit/redeploy the keytab so it contains all of them.
- Never rely on short names.

**If the account / SPN already exist** (rebuild, fix, or this *is* a rotation): running the command above is exactly the right thing — `ktpass` re-derives the key, resets the password to what you type, bumps the KVNO, and emits a fresh keytab. There is no separate "update" command; create and rotate converge here. **The only failure case is a duplicate SPN** — if `setspn -Q oracle/ora01.mylab.local` (next step) returns *more than one* account, or one that is **not** `svc-ora01`, remove the SPN from the wrong account first:

```powershell
setspn -Q oracle/ora01.mylab.local      # see who currently holds it
setspn -D oracle/ora01.mylab.local <WRONG-account>   # repeat per wrong holder
# then re-run the ktpass command above so svc-ora01 holds it cleanly.
```

**Verify the SPN is now registered** (must return exactly one user, `svc-ora01`):

```powershell
setspn -Q oracle/ora01.mylab.local
# Expected: CN=svc-ora01,CN=Users,DC=mylab,DC=local
#           oracle/ora01.mylab.local

setspn -L svc-ora01
# Expected: oracle/ora01.mylab.local
```

**Verify the keytab** (on the DC, locally, before shipping):

```powershell
ktab.exe -l -e -t -k .\ora01.keytab
# Or, after copying to the Linux Oracle host: sudo -u oracle klist -kte ora01.keytab
# Expected: a single entry for oracle/ora01.mylab.local@MYLAB.LOCAL with etype 18 (AES256-CTS-HMAC-SHA1-96), KVNO 2 or higher.
```

**Ship the keytab to the Oracle server** securely (`scp` over SSH, or whatever your file-transfer policy allows). On `ora01`:

```bash
sudo install -m 0640 -o oracle -g oinstall /tmp/ora01.keytab /etc/oracle/keytabs/ora01.keytab
sudo -u oracle klist -kte /etc/oracle/keytabs/ora01.keytab   # confirm
```

> The keytab is the long-term key for `svc-ora01`. Treat it like a private key: 0640 oracle:oinstall, never in version control, deleted from `/tmp` immediately after install.

### A3. Create the LDAP-bind service account `svc-ora-ldap`

This account is what the database uses to **read AD users' group memberships** (for the `ad_sync` reconciliation job). It does *not* need any elevated privileges — just "Read properties" on user objects in the search base. Unlike `svc-ora01`, this account has **no keytab and no SPN** — its password is used directly by Oracle (loaded into the wallet on `ora01`), so the password you set here **is** the authoritative one. Record it in your password vault and hand it to the Oracle DBA out-of-band.

```powershell
# Idempotent: reuse the account if it already exists; only set the password
# if creating fresh (re-runs must not silently change the bind password the
# DBA already loaded into the wallet).
if (Get-ADUser -Filter "SamAccountName -eq 'svc-ora-ldap'" -ErrorAction SilentlyContinue) {
  Write-Host "svc-ora-ldap already exists — leaving its password untouched."
  Write-Host "If you need to rotate it, use Part B3 (it also updates the wallet)."
  Enable-ADAccount -Identity svc-ora-ldap
  Set-ADUser -Identity svc-ora-ldap `
    -UserPrincipalName "svc-ora-ldap@MYLAB.LOCAL" `
    -PasswordNeverExpires $true -CannotChangePassword $true
} else {
  $pw = Read-Host -AsSecureString "NEW password for svc-ora-ldap (store in vault; give to DBA)"
  New-ADUser `
    -Name "svc-ora-ldap" `
    -SamAccountName "svc-ora-ldap" `
    -UserPrincipalName "svc-ora-ldap@MYLAB.LOCAL" `
    -DisplayName "Oracle CMU/AD-sync LDAPS bind account" `
    -Description "Used by ora01 ad_sync package to read group memberships over LDAPS-636" `
    -AccountPassword $pw `
    -Enabled $true `
    -PasswordNeverExpires $true `
    -CannotChangePassword $true `
    -Path "CN=Users,DC=mylab,DC=local"
}

# Optional but recommended: restrict where this account can log on (i.e., not interactive logon anywhere).
# Set-ADUser -Identity svc-ora-ldap -LogonWorkstations "DOES-NOT-EXIST"
```

> **Why `svc-ora01` and `svc-ora-ldap` differ on re-run.** `svc-ora01`'s password is *expected* to change every time `ktpass` runs (the keytab is regenerated to match, so nothing breaks). `svc-ora-ldap`'s password must **not** change on a re-run — Oracle's wallet on `ora01` holds a copy, and changing it in AD without simultaneously updating the wallet (Part B3) breaks the sync with an LDAP bind failure (rc=49). Hence the idempotent guard above only sets the password when creating the account for the first time.

> The account is a "Domain User" by default. That role already grants "Read properties" on most user attributes in `CN=Users,DC=mylab,DC=local`. If your AD has restrictive ACLs on `CN=Users` or custom OUs, explicitly grant `Read` to `svc-ora-ldap` on the user OUs that contain Oracle-relevant accounts.

### A4. Create the AD security groups

```powershell
$ouGroups = "OU=Groups,DC=mylab,DC=local"

# Create the OU if it doesn't exist:
if (-not (Get-ADOrganizationalUnit -Filter 'Name -eq "Groups"' -SearchBase "DC=mylab,DC=local")) {
  New-ADOrganizationalUnit -Name "Groups" -Path "DC=mylab,DC=local"
}

New-ADGroup -Name "oracle-readers" -GroupScope Global -GroupCategory Security `
  -Path $ouGroups -Description "Members get ORA_READERS_ROLE in ORCLPDB1"

New-ADGroup -Name "oracle-writers" -GroupScope Global -GroupCategory Security `
  -Path $ouGroups -Description "Members get ORA_WRITERS_ROLE in ORCLPDB1"
```

### A5. (One-time) Validate AD CS / LDAPS

```powershell
# Confirm the DC presents an LDAPS cert chained to your enterprise root CA.
$d = "ad1.mylab.local"; $p = 636
$tcp = New-Object System.Net.Sockets.TcpClient($d, $p)
$ssl = New-Object System.Net.Security.SslStream($tcp.GetStream(), $false, { $true })
$ssl.AuthenticateAsClient($d)
$cert = [System.Security.Cryptography.X509Certificates.X509Certificate2]$ssl.RemoteCertificate
$cert | Select-Object Subject, Issuer, NotBefore, NotAfter
$ssl.Close(); $tcp.Close()
```

Expected: a cert with `Subject = CN=ad1.mylab.local` issued by your Enterprise Root CA, valid for ~1 year.

If LDAPS is not yet working: install/enable AD Certificate Services Enterprise Root CA on the DC (`Add-WindowsFeature ADCS-Cert-Authority` + `Install-AdcsCertificationAuthority -CAType EnterpriseRootCA`). The DC auto-enrolls for the `Domain Controller` cert template and starts serving LDAPS on 636 within a few minutes.

**Export the Root CA's public certificate** so the Oracle server's wallet can trust it:

```powershell
$ca = Get-CACertificate
$ca.RawData | Set-Content -Encoding Byte C:\temp\mylab-root-ca.cer
# Convert to PEM for Oracle if needed:
certutil -encode C:\temp\mylab-root-ca.cer C:\temp\mylab-root-ca.pem
```

Hand `mylab-root-ca.cer` (or `.pem`) to the Oracle DBA. They add it to the Oracle wallet via `orapki wallet add -trusted_cert`.

---

## Part B — Day-2 operations

### B1. Add a new AD user to one of the Oracle groups

```powershell
# User already exists in AD; just slot them into the right group:
Add-ADGroupMember -Identity oracle-readers -Members <samAccountName>

# Optional: confirm
Get-ADGroupMember -Identity oracle-readers | Select Name, SamAccountName
```

Effect in Oracle:
- **Within 10 minutes** the `ad_sync` scheduler job creates `<UPN-UPPERCASE>` as an `IDENTIFIED EXTERNALLY` user and grants `ORA_READERS_ROLE`.
- **OR**, the next time that user logs in via DBeaver, the `AFTER LOGON` trigger does the same in ~5 ms.

No coordination with the DBA is required for routine group changes.

### B2. Rotate `svc-ora01`'s password (and the keytab)

The lab uses `PasswordNeverExpires=$true`, but corporate password policy may force rotation every N days. The procedure:

1. Pick a new password and rotate AD + keytab in one shot (this is **the same command as the initial keytab generation** — `ktpass` is idempotent in the sense that re-running it resets the password and emits a fresh keytab):

   ```powershell
   ktpass `
     -princ oracle/ora01.mylab.local@MYLAB.LOCAL `
     -mapuser MYLAB\svc-ora01 `
     -pass "<NEW-PASSWORD>" `
     -crypto AES256-SHA1 `
     -ptype KRB5_NT_PRINCIPAL `
     -out .\ora01.keytab
   ```

2. Ship the new keytab to `ora01`, replacing `/etc/oracle/keytabs/ora01.keytab` (0640 oracle:oinstall).

3. Tell the DBA to bounce the Oracle listener (or the whole instance) so the new key is in effect. Any existing user sessions keep working until they reconnect.

4. (Optional but recommended) On the DBA side: `kdestroy && kinit <user>@MYLAB.LOCAL` on a workstation, then verify a fresh connect succeeds. Existing service tickets in client caches still have the OLD `kvno` and will fail until they expire; `kdestroy` flushes them.

If you forget step 2 (deploy the new keytab) you'll see `KRB_AP_ERR_MODIFIED` on the Oracle host the moment any user tries to connect — see [troubleshooting.md#krb-ap-err-modified](../troubleshooting.md#krb-ap-err-modified).

### B3. Rotate `svc-ora-ldap`'s password

This account has no keytab — just a password.

```powershell
$pw = Read-Host -AsSecureString "New password for svc-ora-ldap"
Set-ADAccountPassword -Identity svc-ora-ldap -Reset -NewPassword $pw
```

Tell the DBA to update the wallet entry on `ora01`:

```bash
# As the Oracle DBA on ora01
$ORACLE_HOME/bin/mkstore -wrl /u01/app/oracle/cmu/wallet -modifyEntry ORACLE.SECURITY.PASSWORD <new-password>
# Then restart the listener and confirm sync still runs:
$ORACLE_HOME/bin/lsnrctl reload
sqlplus / as sysdba <<<'ALTER SESSION SET CONTAINER=orclpdb1; EXEC ad_sync.ad_sync.run;'
```

If the wallet is out of sync, you'll see `ORA-28030` returning to DBeaver users, and `AD_SYNC.AD_SYNC_LOG` will show LDAP bind failures with rc=49 ("Invalid Credentials").

### B4. Decommission a user

If a person is leaving the org, disable / delete them in AD as usual. The next `ad_sync` cycle will:
- Revoke their Oracle role grants (so they immediately lose privileges).
- Leave the Oracle external user object in place, locked, for audit-trail purposes. (DBA can `DROP USER … CASCADE` later if they choose.)

There is no AD-admin action specific to Oracle here — group removal does the work.

### B5. Roll the entire setup (e.g. moving Oracle to a new host `ora02`)

You'll re-do Part A:

1. Create `svc-ora02` (or rename — see B6).
2. Generate a new SPN `oracle/ora02.mylab.local` and matching keytab.
3. Existing `svc-ora-ldap`, `oracle-readers`, `oracle-writers` are unchanged.
4. DBA deploys the new keytab on `ora02`.

You can deprecate `svc-ora01` and the old SPN once `ora01` is decommissioned (see Part C).

### B6. Renaming the Oracle host (`ora01` → `ora-prod-01`)

The SPN is keyed to the hostname. If the host's DNS name changes:

```powershell
# Remove the old SPN from the service account:
setspn -D oracle/ora01.mylab.local svc-ora01

# Add the new SPN:
setspn -S oracle/ora-prod-01.mylab.local svc-ora01

# Generate a fresh keytab with the new principal:
ktpass `
  -princ oracle/ora-prod-01.mylab.local@MYLAB.LOCAL `
  -mapuser MYLAB\svc-ora01 `
  -pass "<password>" `
  -crypto AES256-SHA1 `
  -ptype KRB5_NT_PRINCIPAL `
  -out .\ora-prod-01.keytab
```

Then DBA updates `/etc/krb5.conf`'s `default_realm` / `kdc` (unchanged in this case, since realm is the same), the listener.ora/tnsnames.ora hostname references, and `/etc/oracle/keytabs/ora-prod-01.keytab`.

---

## Part C — Cleanup / decommission

### C1. Removing the entire Oracle integration

If the Oracle database is being retired and you want to clean up AD:

```powershell
# 1. Remove SPN
setspn -D oracle/ora01.mylab.local svc-ora01

# 2. Disable + delete the service accounts
Disable-ADAccount -Identity svc-ora01
Disable-ADAccount -Identity svc-ora-ldap
Remove-ADUser    -Identity svc-ora01
Remove-ADUser    -Identity svc-ora-ldap

# 3. Empty + delete the groups
Remove-ADGroup -Identity oracle-readers
Remove-ADGroup -Identity oracle-writers
```

Do NOT remove the Enterprise Root CA from AD CS — many other systems depend on it.

### C2. Removing a duplicate or stale SPN

If `setspn -Q oracle/ora01.mylab.local` returns **more than one user**, you have a duplicate SPN. Symptoms on the Oracle side: `KDC_ERR_S_PRINCIPAL_UNKNOWN` at logon. Fix:

```powershell
setspn -Q oracle/ora01.mylab.local
# Returns multiple CN=... entries

# For each WRONG account holding the SPN, remove it:
setspn -D oracle/ora01.mylab.local <wrong-account>

# Confirm only the intended account remains:
setspn -Q oracle/ora01.mylab.local
```

A duplicate typically appears when `ktpass` is run against a different user account by mistake. After cleanup, regenerate the keytab from the correct account (Part A2) and redeploy on `ora01`.

### C3. Disabling AES enforcement temporarily (debugging only)

If you suspect an enctype mismatch and want to allow RC4 fallback for a single debugging session:

```powershell
Set-ADUser -Identity svc-ora01 -KerberosEncryptionType "AES256, AES128, RC4"
# Then re-run ktpass and redeploy keytab. Once root-caused, revert to AES256 only.
```

Production setting is `AES256` only — RC4 is deprecated and disabled by default in modern Windows.

---

## Validation checklist (run before declaring "done")

On a DC:

```powershell
# All four AD objects exist and are configured right:
Get-ADUser  -Identity svc-ora01     -Properties UserPrincipalName, ServicePrincipalNames, msDS-SupportedEncryptionTypes
Get-ADUser  -Identity svc-ora-ldap  -Properties UserPrincipalName, Enabled, msDS-SupportedEncryptionTypes
Get-ADGroup -Identity oracle-readers -Properties Description
Get-ADGroup -Identity oracle-writers -Properties Description

# Expected on svc-ora01:
#   ServicePrincipalNames = {oracle/ora01.mylab.local}
#   msDS-SupportedEncryptionTypes = 16 (AES256 only)

# SPN is uniquely registered:
setspn -X
# Should report NO duplicate SPNs.

# Members of each group are who you expect:
Get-ADGroupMember oracle-readers | Select Name, SamAccountName, UserPrincipalName
Get-ADGroupMember oracle-writers | Select Name, SamAccountName, UserPrincipalName

# LDAPS works and presents the right cert (Part A5).
```

On the Oracle host (`ora01`):

```bash
# Keytab is in place and matches what AD expects
sudo -u oracle klist -kte /etc/oracle/keytabs/ora01.keytab

# Service ticket can be acquired
kinit -kt /etc/oracle/keytabs/ora01.keytab oracle/ora01.mylab.local
klist

# Sync runs cleanly
sqlplus / as sysdba <<EOF
ALTER SESSION SET CONTAINER = orclpdb1;
TRUNCATE TABLE ad_sync.ad_sync_log;
BEGIN ad_sync.ad_sync.run; END;
/
SELECT TO_CHAR(ts,'HH24:MI:SS.FF3') ts, lvl, msg FROM ad_sync.ad_sync_log ORDER BY ts;
EOF
```

On a Windows client logged in as one of the AD users in the group:

```sql
-- DBeaver SQL editor against ORCLPDB1
SELECT USER, SYS_CONTEXT('USERENV','AUTHENTICATION_METHOD'), ROLE
FROM   DUAL, SESSION_ROLES
WHERE  ROLE LIKE 'ORA_%';
-- Expected: <USER>@MYLAB.LOCAL, KERBEROS, the matching ORA_*_ROLE for their group.
```

If all three checks pass, the AD-side configuration is correct and the system is ready for production use.

---

## Cross-references

- [RECIPE.md](../RECIPE.md) — the Oracle/Windows-side counterpart to this chapter
- [docs/03-ad-and-spn-setup.md](03-ad-and-spn-setup.md) — narrative explanation of the same setup
- [docs/10-operations-rotation.md](10-operations-rotation.md) — keytab rotation procedure in more detail
- [docs/16-cmu-19c-failure-mode.md](16-cmu-19c-failure-mode.md) — why CMU isn't used (background, not actionable for AD admin)
- [docs/17-external-users-and-ad-sync.md](17-external-users-and-ad-sync.md) — what the database side does with the AD groups
- [troubleshooting.md](../troubleshooting.md) — error-message lookup table
