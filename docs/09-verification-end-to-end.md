# 09 · End-to-end verification

This is the formal walkthrough. If every step passes, the runbook is "green." If a step fails, jump to the anchor in [../troubleshooting.md](../troubleshooting.md) listed beside it.

The default path uses **DBeaver only**. There is an **optional** Oracle Instant Client smoke test at the bottom that confirms the Kerberos path at the SQL\*Net layer before introducing DBeaver as a variable — handy when DBeaver fails and you need to know whether the JVM/driver side or the Kerberos side is the broken part.

---

## 0. Prerequisites checklist

Tick all of these before starting:

- [ ] VMs `ad1` and `ora01` are running (`vagrant status` from `..\tableau_ad_oracle\`).
- [ ] `svc-ora01` exists in AD with SPN `oracle/ora01.mylab.local` (script: [../../tableau_ad_oracle/scripts/ad-create-lab-accounts.ps1](../../tableau_ad_oracle/scripts/ad-create-lab-accounts.ps1)).
- [ ] Oracle keytab `ora01.keytab` is deployed at `/etc/oracle/keytabs/ora01.keytab` (script: [../../tableau_ad_oracle/scripts/ktpass-keytabs.ps1](../../tableau_ad_oracle/scripts/ktpass-keytabs.ps1)).
- [ ] Oracle 19c has `sqlnet.ora` with `SQLNET.AUTHENTICATION_SERVICES=(KERBEROS5)` and externally identified user `ALICE@MYLAB.LOCAL` (script: [../../tableau_ad_oracle/scripts/oracle21c-kerberos.sh](../../tableau_ad_oracle/scripts/oracle21c-kerberos.sh) — name says "21c" but applies to 19c identically).
- [ ] Linux-side keytab verification has passed (script: [../../tableau_ad_oracle/scripts/keytab-check.sh](../../tableau_ad_oracle/scripts/keytab-check.sh)).
- [ ] MIT Kerberos for Windows installed (chapter [05](05-windows-client-mit-krb.md)).
- [ ] `C:\ProgramData\MIT\Kerberos5\krb5.ini` in place (chapter [05](05-windows-client-mit-krb.md)).
- [ ] `KRB5CCNAME` set to `FILE:C:\Users\<you>\krb5cc` (chapter [06](06-windows-lsa-and-ccache.md)).
- [ ] DBeaver Oracle driver libraries updated with the four jars (chapter [07](07-dbeaver-oracle-driver.md)).
- [ ] `dbeaver.ini` has the four `-D` JVM args (chapter [08](08-dbeaver-connection.md)).
- [ ] ORCLPDB1 connection saved with `(KERBEROS5)` driver property (chapter [08](08-dbeaver-connection.md)).

---

## 1. Non-interactive preflight

```powershell
PS> cd C:\Users\<you>\Documents\oracle_Ad_kerberos
PS> .\scripts\windows\Invoke-DBeaverPrecheck.ps1
```

Expected last lines:

```
=== Summary ===

Check                                  Result Detail
-----                                  ------ ------
Prereqs (DNS/ports/clock/krb5.ini)     PASS
SPN registration + AES enctype         PASS   unique=1 aes256=True
Oracle listener reachable              PASS   TCP ora01.mylab.local:1521 = True

All checks passed. Open DBeaver and connect to ORCLPDB1.
```

Failure anchors:
- Prereqs FAIL → [troubleshooting.md#clock-skew](../troubleshooting.md#clock-skew), [#dns-resolution](../troubleshooting.md#dns-resolution).
- SPN FAIL → [troubleshooting.md#kdc-err-s-principal-unknown](../troubleshooting.md#kdc-err-s-principal-unknown), [#duplicate-spn](../troubleshooting.md#duplicate-spn).
- Listener FAIL → VM not running, listener not started, or firewall on `ora01`.

## 2. Acquire a TGT

```powershell
PS> kinit alice@MYLAB.LOCAL
Password for alice@MYLAB.LOCAL: ********
```

No output on success. Exit code 0.

Failure anchors:
- `kinit: Preauthentication failed while getting initial credentials` → wrong AD password.
- `kinit: Cannot resolve servers for KDC in realm "MYLAB.LOCAL"` → DNS or hosts file issue. [troubleshooting.md#dns-resolution](../troubleshooting.md#dns-resolution).
- `kinit: Realm not local to KDC` → realm name casing/spelling in `krb5.ini` is wrong. [troubleshooting.md#gss-defective-token](../troubleshooting.md#gss-defective-token) covers casing.
- `kinit: Clock skew too great` → [troubleshooting.md#clock-skew](../troubleshooting.md#clock-skew).

## 3. Inspect the cache

```powershell
PS> klist
Ticket cache: FILE:C:\Users\<you>\krb5cc
Default principal: alice@MYLAB.LOCAL

Valid starting       Expires              Service principal
05/13/2026 09:14:02  05/13/2026 19:14:02  krbtgt/MYLAB.LOCAL@MYLAB.LOCAL
        renew until 05/20/2026 09:14:02
```

Things to check on this output:

- `Ticket cache:` line matches `$env:KRB5CCNAME`. If it says `API:Initial default ccache`, `KRB5CCNAME` is not visible to MIT — fix env-var scope (chapter [06](06-windows-lsa-and-ccache.md)).
- `Default principal:` is `alice@MYLAB.LOCAL`, **case-sensitive**. If it ended up as `alice@mylab.local`, your `krb5.ini` `default_realm` is lower-case — change it.
- Exactly one `krbtgt/MYLAB.LOCAL` entry.

## 4. Request the Oracle service ticket

```powershell
PS> kvno oracle/ora01.mylab.local@MYLAB.LOCAL
oracle/ora01.mylab.local@MYLAB.LOCAL: kvno = 2
```

The `kvno = 2` (or whatever integer) is the **key version number** of the service principal on the AD side. Write it down for keytab rotation [10](10-operations-rotation.md). It must match the kvno embedded in the keytab on `ora01` — run `klist -kte /etc/oracle/keytabs/ora01.keytab` on the Oracle host if you suspect drift.

Failure anchors:
- `kvno: Server not found in Kerberos database` → SPN missing on AD. [troubleshooting.md#kdc-err-s-principal-unknown](../troubleshooting.md#kdc-err-s-principal-unknown).
- `kvno: KDC has no support for encryption type` → enctype mismatch. [troubleshooting.md#enctype-mismatch](../troubleshooting.md#enctype-mismatch).

After a successful kvno, klist now lists both entries:

```powershell
PS> klist
Ticket cache: FILE:C:\Users\<you>\krb5cc
Default principal: alice@MYLAB.LOCAL

Valid starting       Expires              Service principal
05/13/2026 09:14:02  05/13/2026 19:14:02  krbtgt/MYLAB.LOCAL@MYLAB.LOCAL
        renew until 05/20/2026 09:14:02
05/13/2026 09:14:15  05/13/2026 19:14:02  oracle/ora01.mylab.local@MYLAB.LOCAL
        renew until 05/20/2026 09:14:02
```

## 5. DBeaver: Test Connection

Open DBeaver. Right-click the `ORCLPDB1` connection → **Test Connection…**.

Expected: green dialog, `Server: Oracle Database 19c Enterprise Edition Release 19.0.0.0.0`. See ASCII mockup in chapter [08](08-dbeaver-connection.md), section 4. Screenshot: [../screenshots/README.md](../screenshots/README.md) item 04.

Failure anchors:
- `ORA-12631` / `ORA-12638` → [troubleshooting.md#ora-12638](../troubleshooting.md#ora-12638).
- `KrbException: Identifier doesn't match expected value (906)` → [troubleshooting.md#enctype-mismatch](../troubleshooting.md#enctype-mismatch).
- `GSS-API: Defective token detected` → [troubleshooting.md#gss-defective-token](../troubleshooting.md#gss-defective-token).
- `NoClassDefFoundError: oracle/security/o5logon/...` → companion jars missing, see chapter [07](07-dbeaver-oracle-driver.md) section 5.

## 6. DBeaver: confirm the identity

Open a SQL editor on the saved connection. Run:

```sql
SELECT USER,
       SYS_CONTEXT('USERENV', 'AUTHENTICATION_METHOD') AS AUTH_METHOD,
       SYS_CONTEXT('USERENV', 'AUTHENTICATED_IDENTITY') AS AUTH_IDENT,
       SYS_CONTEXT('USERENV', 'OS_USER')                AS OS_USER
  FROM DUAL;
```

Expected row:

| USER | AUTH_METHOD | AUTH_IDENT | OS_USER |
|---|---|---|---|
| `ALICE@MYLAB.LOCAL` | `KERBEROS` | `alice@MYLAB.LOCAL` | *(client OS user)* |

If `AUTH_METHOD` is `PASSWORD`, the connection slipped back to native auth — re-check the connection's **Driver properties** tab for `oracle.net.authentication_services=(KERBEROS5)` (chapter [08](08-dbeaver-connection.md)).

If `USER` is correct but you wanted a different identity (e.g. `bob`), `kinit bob@MYLAB.LOCAL` to overwrite the ccache, reconnect in DBeaver, and re-run the query.

## 7. (Done.)

At this point the auth path is proven end-to-end. Operational concerns (keytab rotation, kvno bumps, ticket-lifetime monitoring) live in [10 · Operations and rotation](10-operations-rotation.md).

---

## Optional — Oracle Instant Client smoke test

This section is independent of DBeaver. It tests the **same Kerberos credentials** through SQL\*Plus, removing the JDBC driver and the JVM from the picture. Useful when:

- DBeaver fails and you want to bisect: is the problem in JDBC/JVM, or below?
- You want a scripted regression check that doesn't depend on a GUI.

### Install Instant Client

1. Download **Oracle Instant Client Basic** + **SQL\*Plus Package** for Windows x64:
   <https://www.oracle.com/database/technologies/instant-client/winx64-64-downloads.html>
2. Extract both zips into one directory, e.g. `C:\oracle\instantclient_21_12\`.
3. Set environment variables (User scope):
   ```powershell
   PS> [Environment]::SetEnvironmentVariable("ORACLE_HOME", "C:\oracle\instantclient_21_12", "User")
   PS> [Environment]::SetEnvironmentVariable("TNS_ADMIN",   "C:\oracle\instantclient_21_12\network\admin", "User")
   PS> [Environment]::SetEnvironmentVariable("PATH",        "$env:PATH;C:\oracle\instantclient_21_12", "User")
   ```
4. Create `C:\oracle\instantclient_21_12\network\admin\tnsnames.ora` with the same entry as the server side ([../../tableau_ad_oracle/config/oracle-tnsnames.ora.example](../../tableau_ad_oracle/config/oracle-tnsnames.ora.example)):
   ```
   ORCLPDB1 =
     (DESCRIPTION =
       (ADDRESS = (PROTOCOL = TCP)(HOST = ora01.mylab.local)(PORT = 1521))
       (CONNECT_DATA = (SERVER = DEDICATED) (SERVICE_NAME = orclpdb1))
     )
   ```
5. Create `C:\oracle\instantclient_21_12\network\admin\sqlnet.ora` matching [../../tableau_ad_oracle/config/oracle-sqlnet.ora.example](../../tableau_ad_oracle/config/oracle-sqlnet.ora.example) but with **Windows paths**:
   ```
   SQLNET.AUTHENTICATION_SERVICES = (KERBEROS5)
   SQLNET.KERBEROS5_CONF = C:\ProgramData\MIT\Kerberos5\krb5.ini
   SQLNET.KERBEROS5_CONF_MIT = TRUE
   SQLNET.KERBEROS5_CC_NAME = C:\Users\<you>\krb5cc
   SQLNET.FALLBACK_AUTHENTICATION = FALSE
   ```
   > `SQLNET.KERBEROS5_CC_NAME` here is the bare path (no `FILE:` prefix) — that's the SQL\*Net convention, distinct from the JVM convention.
6. Open a **new** PowerShell window so the env vars take effect.

### Run the smoke test

```powershell
PS> kinit alice@MYLAB.LOCAL          # password prompt
PS> tnsping ORCLPDB1                 # expect "OK (xx msec)"
PS> sqlplus -L /@ORCLPDB1
SQL*Plus: Release 19.0.0.0.0 ...
Connected to:
Oracle Database 19c Enterprise Edition Release 19.0.0.0.0 - Production
SQL> SELECT USER FROM DUAL;
USER
------------------------------
ALICE@MYLAB.LOCAL
SQL> EXIT
```

If this works but DBeaver doesn't, the problem is somewhere in the JDBC/JVM layer:
- Companion jars (chapter [07](07-dbeaver-oracle-driver.md) section 5)
- JVM args in `dbeaver.ini` (chapter [08](08-dbeaver-connection.md) section 1)
- Or `KRB5CCNAME` not visible to DBeaver (chapter [06](06-windows-lsa-and-ccache.md) section 2d)

If both work, the lab is fully green.
