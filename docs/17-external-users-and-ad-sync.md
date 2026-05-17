# 17 · External users + AD-driven sync (the working Kerberos pattern)

This is what the lab actually ships. See chapter [16](16-cmu-19c-failure-mode.md) for why we do not use Oracle Centrally Managed Users (CMU) on 19c, and chapter [20](20-architecture-and-hardening.md) for the architecture rationale (this is **Kerberos authentication + LDAP-driven authorization/materialization**, not native CMU), the fail-open trigger decision, and the production hardening checklist.

> **End-user behaviour is identical to CMU:** Windows-logged-in AD user opens DBeaver, hits ENTER, runs queries; no Oracle password, no `kinit`, privileges come from AD group membership. The only differences are operational, behind the scenes.

---

## Architecture

```
   AD groups                Oracle DB
   (truth)                  (mirrors AD)

  oracle-readers   --→     ORA_READERS_ROLE  ── SELECT ANY TABLE
                              │
                              ↓ granted to
                           ALICE@MYLAB.LOCAL  (EXTERNAL Oracle user)
                           CAROL@MYLAB.LOCAL  (EXTERNAL Oracle user)

  oracle-writers   --→     ORA_WRITERS_ROLE  ── SELECT/INSERT/UPDATE/DELETE
                              │
                              ↓ granted to
                           BOB@MYLAB.LOCAL    (EXTERNAL Oracle user)
```

- **Authentication** is pure Kerberos. An external Oracle user (`"ALICE@MYLAB.LOCAL" IDENTIFIED EXTERNALLY`) has no Oracle password and can only log in by presenting an AD Kerberos service ticket — which DBeaver does automatically when the workstation is domain-joined.
- **Authorization** is via Oracle roles, granted/revoked by a small reconciliation package (`AD_SYNC.AD_SYNC`) that reads AD group membership over LDAPS-636 using the existing CMU wallet.
- The reconciliation runs both on a 10-minute `DBMS_SCHEDULER` job (idle-time correction) and inside an `AFTER LOGON` trigger (JIT correction at each connect).

---

## Why this pattern instead of CMU

See chapter [16](16-cmu-19c-failure-mode.md). Short version: Oracle 19c's CMU code path closes the LDAPS TCP connection 6 ms after establishing it, with no TLS Client Hello sent — every documented configuration produces `ORA-28030`. The wallet, cert, AD permissions, and network path are all individually validated working (`DBMS_LDAP` from PL/SQL succeeds on the same wallet). The bug lives somewhere inside Oracle's `ntz` TLS init layer.

Rather than block on an Oracle Support SR, the lab calls into the LDAP path Oracle DOES expose to PL/SQL (`DBMS_LDAP`), and orchestrates the same end state.

---

## The pieces, in order

### 1 · Roles

```sql
CREATE ROLE ora_readers_role;
GRANT CREATE SESSION TO ora_readers_role;
GRANT SELECT ANY TABLE TO ora_readers_role;

CREATE ROLE ora_writers_role;
GRANT CREATE SESSION TO ora_writers_role;
GRANT SELECT ANY TABLE TO ora_writers_role;
GRANT INSERT ANY TABLE, UPDATE ANY TABLE, DELETE ANY TABLE TO ora_writers_role;
```

Adjust the privileges to whatever your application needs. Adding a new permission set later is a new role + grants; nothing in the sync code changes.

### 2 · The wallet (already in place from the CMU attempt)

`/u01/app/oracle/cmu/wallet/` contains:

- Auto-login: `cwallet.sso` (no password required by the DB to read it)
- Trusted cert: `CN=mylab-root-ca,DC=mylab,DC=local` (the AD CS Enterprise Root CA — pinned via `orapki wallet add -trusted_cert`)
- Secret store entries: `ORACLE.SECURITY.USERNAME=svc-ora-ldap`, `ORACLE.SECURITY.DN=CN=svc-ora-ldap,CN=Users,DC=mylab,DC=local`, `ORACLE.SECURITY.PASSWORD=<the AD password>` (used by CMU even though CMU isn't enabled — `mkstore -createEntry` adds them in the format the docs require)

Ownership: `oracle:oinstall`, 0600. The sync package uses **the same wallet** via `DBMS_LDAP.open_ssl(... 'file:/u01/app/oracle/cmu/wallet' ...)`. Nothing is duplicated.

### 3 · The sync owner schema

A dedicated, login-less schema holds the package. This keeps system-wide grants out of `SYS`:

```sql
CREATE USER ad_sync NO AUTHENTICATION;
GRANT CREATE SESSION       TO ad_sync;
GRANT CREATE PROCEDURE     TO ad_sync;
GRANT UNLIMITED TABLESPACE TO ad_sync;
GRANT EXECUTE ON DBMS_LDAP TO ad_sync;
GRANT SELECT ON DBA_USERS, DBA_ROLE_PRIVS TO ad_sync;
GRANT CREATE USER, ALTER USER, DROP USER  TO ad_sync;
GRANT GRANT ANY ROLE       TO ad_sync;
GRANT GRANT ANY PRIVILEGE  TO ad_sync;
```

### 4 · Network ACL (must-have)

12c+ requires an ACL grant for outbound network from PL/SQL. Without this the package fails with `ORA-24247`:

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
```

### 5 · The package

`AD_SYNC.AD_SYNC` exposes two procedures:

```text
PROCEDURE run                                  -- full reconciliation; called by scheduler
PROCEDURE refresh_user_roles(p_principal ...)  -- single user; called by AFTER LOGON trigger
```

Both use the same primitives:

- `ldap_open()` — `DBMS_LDAP.init('ad1.mylab.local', 636)` → `open_ssl('file:/u01/app/oracle/cmu/wallet', NULL, 2)` → `simple_bind_s('svc-ora-ldap@MYLAB.LOCAL', '<password from wallet>')`.
- `members_of_group(group_dn)` — runs `(&(objectClass=user)(memberOf=<group_dn>))` over `DC=mylab,DC=local`, returns a list of `userPrincipalName` (uppercased to match Oracle's external-user case convention).
- `groups_of_user(p_upn)` — single search `(userPrincipalName=<upn>)`, returns the user's `memberOf` list.
- `ensure_user(p_upn)` — `CREATE USER "<UPN>" IDENTIFIED EXTERNALLY` if not present; unlock if locked.
- `grant_role(p_upn, p_role)` / `revoke_role(p_upn, p_role)` — idempotent, no-ops if already in desired state.

The mapping of AD group → Oracle role is hard-coded in `group_map()`:

```text
'CN=oracle-readers,OU=Groups,DC=mylab,DC=local' → 'ORA_READERS_ROLE'
'CN=oracle-writers,OU=Groups,DC=mylab,DC=local' → 'ORA_WRITERS_ROLE'
```

Add a new group → role mapping there. Re-deploy the package. Done.

Every action goes through an autonomous-transaction `log(level, msg)` writing to `AD_SYNC.AD_SYNC_LOG` — so a failed sync is debuggable from SQL even when the scheduler swallows the error:

```sql
SELECT TO_CHAR(ts,'HH24:MI:SS.FF3'), lvl, msg
FROM ad_sync.ad_sync_log ORDER BY ts;
```

### 6 · The scheduler job

```sql
DBMS_SCHEDULER.create_job(
  job_name        => 'AD_SYNC.AD_SYNC_JOB',
  job_type        => 'PLSQL_BLOCK',
  job_action      => 'BEGIN ad_sync.ad_sync.run; END;',
  start_date      => SYSTIMESTAMP,
  repeat_interval => 'FREQ=MINUTELY; INTERVAL=10',
  enabled         => TRUE);
```

Bound that on memory/CPU: each tick is one LDAPS bind + two LDAP searches + a small number of `EXECUTE IMMEDIATE` statements. Costs nothing in practice.

### 7 · The AFTER LOGON trigger (JIT)

```sql
CREATE OR REPLACE TRIGGER sys.ad_sync_on_logon
AFTER LOGON ON DATABASE
DECLARE
  v_user VARCHAR2(256) := SYS_CONTEXT('USERENV','SESSION_USER');
BEGIN
  IF v_user LIKE '%@MYLAB.LOCAL' THEN
    BEGIN
      ad_sync.ad_sync.refresh_user_roles(v_user);
    EXCEPTION WHEN OTHERS THEN NULL;   -- never block a login on sync failure
    END;
  END IF;
END;
/
```

Fires for every Kerberos-authenticated external user. Adds two LDAP searches (~5 ms typical) to each connect. The `WHEN OTHERS THEN NULL` is deliberate — a transient AD outage must not lock people out of the database; they'll fall back to whatever role grants existed from the last successful sync (this is **fail-open by design** — see [chapter 20 §2](20-architecture-and-hardening.md) for why fail-closed here would be an auth-DoS).

A **circuit breaker** in the package backs this up: after 3 consecutive LDAP failures `ldap_open()` fails fast for a 300 s cooldown *without* touching the network, so a sustained DC outage cannot add bind latency to every login; it self-resets on the first good bind. `ensure_user` also guards the concurrent-first-login `CREATE USER` race. With these shipped the trigger is production-acceptable; **scheduler-only** (disable this trigger, keep the 10-min job) remains the conservative default if you want the login path fully decoupled from LDAP. Details + tunables: [chapter 20 §2](20-architecture-and-hardening.md).

---

## Verified end-to-end behaviour

On `wks01` (domain-joined Win11, logged in as `MYLAB\alice`), in DBeaver Community 25.3.4 connected to `orclpdb1`:

```sql
SELECT USER FROM DUAL;
-- ALICE@MYLAB.LOCAL

SELECT SYS_CONTEXT('USERENV','AUTHENTICATION_METHOD'),
       SYS_CONTEXT('USERENV','SESSION_USER'),
       SYS_CONTEXT('USERENV','OS_USER')
FROM DUAL;
-- KERBEROS | ALICE@MYLAB.LOCAL | alice@MYLAB.LOCAL

SELECT ROLE FROM SESSION_ROLES;
-- ORA_READERS_ROLE

SELECT COUNT(*) FROM ALL_TABLES;
-- 691     (role grants SELECT ANY TABLE; query works)
```

No password prompt at any step. Alice's TGT is the Windows native LSA cache; DBeaver picks it up via `useSubjectCredsOnly=false` in `dbeaver.ini`.

---

## Day-2 operations

### Add a new AD user `dave` to the `oracle-readers` group

```powershell
PS> Add-ADGroupMember oracle-readers dave
```

What happens next:

- **Within 10 minutes** the scheduled job creates `DAVE@MYLAB.LOCAL` `IDENTIFIED EXTERNALLY` in `orclpdb1` and grants `ORA_READERS_ROLE`. No DBA action required.
- **OR**, the first time Dave opens DBeaver after the AD change, the AFTER LOGON trigger does the same in ~5 ms, and Dave's first query already runs with `ORA_READERS_ROLE` active.

### Remove `alice` from `oracle-readers`

```powershell
PS> Remove-ADGroupMember oracle-readers alice
```

- The next scheduler tick revokes `ORA_READERS_ROLE` from `ALICE@MYLAB.LOCAL`.
- Alice's Oracle user record stays (locked accounts preserve audit history); she just can't read tables.
- If we ever want to drop her too, that's one `DROP USER` away — but a real environment usually keeps the record around.

### Change what `oracle-readers` is allowed to do in Oracle

Edit grants on `ORA_READERS_ROLE`. Sync doesn't manage role contents — only role membership.

### Adding a third AD group → role

Edit `group_map()` in the package body, redeploy. Add the new role separately with whatever grants you want. The two existing groups keep working unchanged.

---

## Installer

Everything in this chapter (roles, owner schema, ACL, package, log table, scheduler, trigger) is in [`../scripts/oracle/ad-sync-install.sql`](../scripts/oracle/ad-sync-install.sql). Drop-and-recreate, idempotent. Run it as SYSDBA against `orclpdb1`.

---

## What this pattern DOES NOT do

- No SYSDBA / SYSOPER via AD. CMU does that via `LDAP_DIRECTORY_SYSAUTH=YES`; this pattern doesn't. Admin logins still use local Oracle accounts.
- No PKI / smart-card auth. Same answer.
- No Enterprise User Security features (proxy users, enterprise roles distinct from DB roles, etc.).

For everything Kerberos + AD-group-driven RBAC, which is what 95% of "AD users → Oracle" deployments actually want, this is the working pattern on 19c.
