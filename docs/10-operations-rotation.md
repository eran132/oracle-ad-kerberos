# 10 · Operations and keytab rotation

The runbook is "done" the moment you finish [09](09-verification-end-to-end.md). This chapter is for the second time you touch this lab — months later, when something rotated, expired, or drifted.

---

## What can change over time

| Thing | Why it changes | Effect |
|---|---|---|
| `svc-ora01` password | Manual reset, group policy, accidental `Reset-Password` | Keytab no longer decrypts STs → `KRB_AP_ERR_MODIFIED` |
| Keytab regenerated on DC | `ktpass` re-run | New kvno; old STs in client caches stop working |
| `msDS-SupportedEncryptionTypes` on `svc-ora01` | AD admin tightens / loosens crypto policy | Possibly `KDC has no support for encryption type` |
| Domain user account locked / disabled | Inactivity, policy | `alice` can't `kinit` |
| AD time / Oracle host time drift | VMs suspended, NTP off | Tickets fail validation > 300 s skew |
| TGT lifetime | Default 10 h on AD | Quiet failure after lunch; need to `kinit` again |
| AD domain functional level upgrade | Rare | Possibly enctype changes |

## Routine checks

Run **monthly** (or before any demo):

```powershell
# Windows host
PS> cd C:\Users\<you>\Documents\oracle_Ad_kerberos
PS> .\scripts\windows\Invoke-DBeaverPrecheck.ps1 -DoKinit
```

Run **occasionally** on `ora01`:

```bash
[ora01]$ sudo -u oracle klist -kte /etc/oracle/keytabs/ora01.keytab
[ora01]$ /home/vagrant/scripts/keytab-check.sh
```

Compare:
- KVNO from `klist -kte` on the keytab
- KVNO returned by `kvno oracle/ora01.mylab.local@MYLAB.LOCAL` on the Windows host

They must match. If they don't, the keytab is older than the AD password — rotate.

## Keytab rotation procedure

This is the procedure to use whenever `svc-ora01`'s password has changed, or you've changed `msDS-SupportedEncryptionTypes` and the new enctype must take effect.

### Step 1 — Regenerate keytab on the DC

```powershell
# On ad1, as Domain Admin
PS> cd C:\Users\<you>\Documents\tableau_ad_oracle
PS> .\scripts\ktpass-keytabs.ps1
```

The script overwrites `out\ora01.keytab` and sets `svc-ora01`'s password to the value baked into the script's SecureString. KVNO on the AD object increments by 1.

### Step 2 — Deploy to the Oracle host

```powershell
PS> scp .\out\ora01.keytab vagrant@ora01.mylab.local:/tmp/
```

```bash
# On ora01
[ora01]$ sudo install -m 0640 -o oracle -g oinstall /tmp/ora01.keytab /etc/oracle/keytabs/ora01.keytab
[ora01]$ sudo -u oracle klist -kte /etc/oracle/keytabs/ora01.keytab
# Verify the KVNO matches what the DC now shows.
```

### Step 3 — Reload the listener *(optional but recommended)*

Oracle caches the keytab once loaded; for a clean state:

```bash
[ora01]$ sudo -u oracle lsnrctl reload
```

### Step 4 — Invalidate client caches

Old service tickets in user caches now decrypt against the old key. They will fail until they expire (TGT lifetime). Faster:

```powershell
PS> kdestroy
PS> kinit alice@MYLAB.LOCAL
PS> kvno oracle/ora01.mylab.local@MYLAB.LOCAL   # should report the new KVNO
```

### Step 5 — Confirm DBeaver

Reconnect in DBeaver, run `SELECT USER FROM DUAL;`. If the result is `ALICE@MYLAB.LOCAL`, rotation is clean.

## TGT lifetime and renewal

Default AD TGT lifetime: ~10 hours. Renewable for 7 days. After 10 h of idle DBeaver, the next query will fail with credential errors and you'll need a fresh `kinit`.

To proactively renew:

```powershell
PS> kinit -R    # renew the existing TGT (must still be within renewable window)
```

For long-running ETL or BI sessions, schedule a Task Scheduler job that runs `kinit -R` every 8 h while the user is logged in. Out of scope for this lab.

## Adding a new AD user

Two-side change:

1. **AD side** (on `ad1`):
   ```powershell
   > New-ADUser -Name "dave" -SamAccountName "dave" `
       -UserPrincipalName "dave@MYLAB.LOCAL" `
       -AccountPassword (Read-Host -AsSecureString) -Enabled $true
   ```

2. **Oracle side** (on `ora01`, as SYSDBA in the PDB):
   ```sql
   ALTER SESSION SET CONTAINER = orclpdb1;
   CREATE USER "DAVE@MYLAB.LOCAL" IDENTIFIED EXTERNALLY;
   GRANT CONNECT, CREATE SESSION TO "DAVE@MYLAB.LOCAL";
   ```

3. **Windows client:** `kinit dave@MYLAB.LOCAL`, reconnect DBeaver. (The same DBeaver connection works; principal is read from the ccache.)

## Removing a user

```sql
DROP USER "ALICE@MYLAB.LOCAL" CASCADE;
```

In AD: `Remove-ADUser alice`. The DBeaver connection remains technically functional but every login attempt by Alice will fail at the Oracle "user not found externally" step.

## Audit checklist (annual or before handover)

- [ ] `setspn -X` (or `setspn -Q oracle/ora01.mylab.local`) returns exactly one CN.
- [ ] `msDS-SupportedEncryptionTypes` on `svc-ora01` includes AES256 only (0x10), no RC4.
- [ ] Keytab file permissions on `ora01`: 0640 oracle:oinstall.
- [ ] `sqlnet.ora` has `SQLNET.FALLBACK_AUTHENTICATION = FALSE`.
- [ ] `DBA_USERS` rows for external identities show `AUTHENTICATION_TYPE = EXTERNAL` and have no stored password hash.
- [ ] No human accounts have `PasswordNeverExpires`.
- [ ] DBeaver connection on each analyst's workstation has `oracle.net.authentication_services=(KERBEROS5)` and **no saved password**.
- [ ] `Invoke-DBeaverPrecheck.ps1 -DoKinit` returns all PASS for at least one test user (alice/bob/carol).

If you cannot tick any item above, the rotation/operations response is the corresponding section in this chapter or [troubleshooting.md](../troubleshooting.md).
