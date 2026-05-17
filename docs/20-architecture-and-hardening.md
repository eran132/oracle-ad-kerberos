# 20 · Architecture rationale, security model & hardening

Read this before you conclude "this is native Oracle Kerberos auth." It is not. This chapter states the model explicitly, the trade-offs taken, and the hardening you should apply before production.

---

## 1 · What this system actually is

> **Kerberos authentication + LDAP-driven authorization/materialization.**

Not Oracle Centrally Managed Users (CMU), not Enterprise User Security (EUS). The flow is:

```
AD (source of truth)
   │  Kerberos  ── authentication ──►  Oracle proves the user is alice@MYLAB.LOCAL
   │  LDAPS     ── authorization ──►   ad_sync reads memberOf, materializes:
   │                                     - an EXTERNAL Oracle user per AD member
   │                                     - role grants matching AD group membership
```

Authentication is genuinely Kerberos (no password). Authorization is **materialized**: Oracle ends up holding *copies* of AD state (external users + role grants), reconciled by the `ad_sync` package. See [docs/16](16-cmu-19c-failure-mode.md) for why CMU was rejected and [docs/17](17-external-users-and-ad-sync.md) for the mechanism.

### Trade-offs — state them to stakeholders

**Advantages**

- Deterministic and auditable — Oracle role grants are concrete, inspectable rows.
- Easy to troubleshoot — `ad_sync.ad_sync_log` shows exactly what happened.
- No Oracle Internet Directory / OUD, no EUS complexity.
- Sidesteps the Oracle 19c CMU+Kerberos bug entirely.

**Drawbacks (must be accepted explicitly)**

- **Eventual consistency.** AD change → Oracle effect has latency (scheduler interval; near-zero if the logon trigger is enabled — see §2).
- **Oracle users are materialized copies of AD state**, not live references. A user dropped in AD still has an Oracle row until the next sync revokes/locks it.
- **The sync package is now security infrastructure.** Its correctness, its `AD_SYNC` schema privileges (`GRANT ANY ROLE`, `CREATE USER`), and its wallet credential are all in the trust boundary. Treat changes to it like changes to an auth system.
- **Revocation latency exists.** Removing someone from an AD group does not instantly revoke their Oracle role; it takes effect on the next sync. For immediate revocation, run `ad_sync.ad_sync.run` manually or disable the Oracle account directly.

---

## 2 · The logon-trigger decision (read before enabling it)

The installer ships an `AFTER LOGON` trigger that calls `ad_sync.refresh_user_roles` for the connecting principal, giving near-zero authorization latency. **This couples the login path to LDAP reachability and is a deliberate, debatable choice.**

### Failure direction: this trigger fails OPEN, on purpose

The trigger body is wrapped `EXCEPTION WHEN OTHERS THEN NULL`. If AD/LDAP is unreachable or the bind fails, **the login still succeeds** — the user simply keeps whatever roles the last successful scheduler run granted.

This is intentional and is the opposite of a "fail closed" auth control. Rationale: failing **closed** here would mean *an AD or network outage locks every Kerberos user out of the database* — converting a directory hiccup into a full authentication denial-of-service. For an authorization-*materialization* step (the user is already authenticated by Kerberos at this point), degrading to "stale-but-working privileges" is strictly safer than "no access at all." A reviewer's instinct to "fail closed" is correct for an authentication gate; this is not one.

### Recommended posture

- **Default: scheduler-only.** The 10-minute `DBMS_SCHEDULER` job is sufficient for most environments and keeps the login path completely independent of LDAP. This is the conservative production default.
- **Opt-in: the logon trigger**, only when sub-10-minute authorization latency is a hard requirement, and only with the hardening below.

To run scheduler-only, after install:

```sql
ALTER TRIGGER sys.ad_sync_on_logon DISABLE;
-- the AD_SYNC.AD_SYNC_JOB scheduler job keeps running.
```

### Trigger hardening — shipped in `ad-sync-install.sql`

The package now includes the hardening that makes the trigger path safe to enable:

- **Circuit breaker** (`ad_sync.ad_sync_breaker` table + `breaker_is_open`/`breaker_success`/`breaker_failure`). After `c_breaker_threshold` (default **3**) consecutive LDAP failures the breaker *opens* for `c_breaker_cooldown` (default **300 s**); during that window `ldap_open()` fails fast **without touching the network**, so a DC outage cannot add bind latency to every login. It self-heals: the first successful bind after recovery calls `breaker_success` and resets the counter. State is maintained via autonomous transactions so it survives the caller's rollback. Verified on the live lab: with `ad1` down, a sync attempt logged `ORA-31203` and the breaker correctly incremented `consec_failures`.
- **Duplicate-create race guard**: concurrent first-logins of the same new principal (two `AFTER LOGON` triggers both seeing the user absent) no longer error — `ensure_user` swallows `ORA-01920`/`ORA-00955` ("created concurrently") and re-raises anything else.
- **Failure logging outside the login transaction**: the autonomous-transaction `log()` already does this and is preserved; breaker state writes are likewise autonomous.

Tunables are constants at the top of the package body (`c_breaker_threshold`, `c_breaker_cooldown`) — adjust and re-run the installer to change them.

**Still NOT a per-call network timeout.** `DBMS_LDAP`'s `search_st`/`set_option` timeout surface has version-dependent record/constant names across 19c builds, so a portable per-call timeout is deliberately not shipped (guessing the API risks a package that won't compile on some builds). The circuit breaker bounds the *aggregate* exposure instead — a single hung call is still possible but is governed by Oracle's own TCP timeout and cannot repeat for every login once the breaker trips. Adding `search_st` with the build-correct `TIMEVAL` fields is a safe optional tightening if you validate it against your exact 19c build first.

Net guidance: with the breaker shipped, the logon trigger is acceptable for production; **scheduler-only remains the conservative default** if you want the login path fully decoupled from LDAP regardless.

---

## 3 · DNS / name-resolution guidance

Kerberos is acutely sensitive to name resolution. Most "mysterious" Kerberos failures are DNS, not Kerberos.

- **Forward and reverse DNS must agree.** `ora01.mylab.local` → IP, and the PTR for that IP → `ora01.mylab.local`. A mismatched/absent PTR causes intermittent `KRB_AP_ERR_*` failures depending on client canonicalization settings.
  ```bash
  host ora01.mylab.local        # forward
  host <that-ip>                # reverse — must return ora01.mylab.local
  ```
- **No split-brain DNS.** The name a client resolves must be the same name the SPN was registered for (see §A2 "SPN must match exactly").
- **Minimize `/etc/hosts` reliance.** Step 13 adds host entries as a lab convenience so an AD-side DNS hiccup doesn't take the demo down. In production this *masks* real DNS problems and creates split-brain between what `ora01` resolves and what clients resolve. Prefer correct DNS + reverse zones; treat `/etc/hosts` overrides as lab/testing only, and document any that remain.

---

## 4 · Tested version matrix

Oracle Kerberos behavior changes across JVM and driver versions (the `forwardable=false` and `getKRBCredForDelegation` issues are JVM-version-sensitive). Pin and record what you validated; treat upgrades to any row as a re-test trigger.

| Component | Tested version (2026-05) |
|---|---|
| Oracle Database | 19c, 19.30.0.0 (Enterprise Edition) |
| Oracle JDBC | `ojdbc8` 23.3.0.23.09 + `oraclepki`/`osdt_core`/`osdt_cert` 21.9.0.0 |
| DBeaver | Community 25.3.x (bundles its own JRE) |
| Client JRE (bundled by DBeaver) | Java 21 |
| MIT Kerberos for Windows (non-domain client) | 4.1.x |
| AD / DC | Windows Server 2022 |
| Oracle host OS | RHEL 9 |

---

## 5 · Wallet & credential handling

The Oracle wallet at `/u01/app/oracle/cmu/wallet/` is **auto-login** (`cwallet.sso`). That is a deliberate convenience — the DB reads the LDAP bind credential without a prompt — but it means:

> **Filesystem read access to the wallet directory == possession of the `svc-ora-ldap` AD bind credential.**

Mitigations:

- Directory ownership `oracle:oinstall`, mode `700`; files `600`. (Step 18 / [RECIPE.md](../RECIPE.md) enforce this.)
- **Never back up the wallet unencrypted.** Exclude it from generic backup jobs or ensure backup-at-rest encryption.
- Reduce sudo surface to the `oracle` account; the bind credential is only as protected as "who can become `oracle` or read its files."
- Consider filesystem encryption for the wallet path, and SELinux confinement of the Oracle processes if your baseline supports it.
- `svc-ora-ldap` must have **only** directory read on the user/group OUs it queries — no write, no elevated rights. It is a read-only directory reader; scope it that way in AD.

---

## 6 · External-user identity caveats

`ad_sync` creates Oracle users named exactly `ALICE@MYLAB.LOCAL` (UPN, upper-cased). Good for collision-avoidance, but be aware:

- The Oracle username is logically a **case-and-realm-bound identity string**. The realm suffix is part of the identity.
- **Realm renames / UPN-suffix changes are painful** — every external Oracle user's name embeds `@MYLAB.LOCAL`. Changing the AD UPN suffix means re-materializing every user under the new name and migrating their grants. Plan UPN suffixes you can live with long-term.
- Cross-realm trust scenarios (users from `OTHER.LOCAL` connecting) require the sync mapping and the external-user naming to account for the foreign realm explicitly.

---

## 7 · Hardening checklist (apply before production)

- [ ] **Disable RC4 domain-wide** if policy allows; otherwise at minimum pin `svc-ora01` and `svc-ora-ldap` to AES256 (`msDS-SupportedEncryptionTypes` = 16) and verify (see [docs/19 §A2](19-ad-admin-runbook.md)).
- [ ] **Enforce AES256 only** end-to-end: AD account, keytab (`klist -kte` shows etype 18), `sqlnet.ora`, client `krb5.ini`.
- [ ] **Rotate service passwords periodically**: `svc-ora01` via keytab rotation ([docs/10](10-operations-rotation.md)); `svc-ora-ldap` via runbook Part B3 (and update the wallet).
- [ ] **Enable Oracle Unified Auditing** for logon (success+failure) on the external users and for `AD_SYNC` package executions.
- [ ] **Monitor failed Kerberos logons** (`ORA-01017`/`ORA-12638` spikes) and `ad_sync.ad_sync_log` `ERROR` rows (LDAP bind failures, rc=49).
- [ ] **Restrict `svc-ora-ldap`** to read-only on the specific user/group OUs; deny interactive logon.
- [ ] **Firewall Oracle ⇄ DC** to only the required ports (88, 389/636, 464) in only the required directions.
- [ ] **TLS posture for LDAPS**: enforce TLS 1.2+ on the DC; the wallet trusts only the lab Root CA, not a broad CA set.
- [ ] **FIPS caveat**: if the host runs in FIPS mode, validate the JDBC/MIT Kerberos crypto path explicitly — some enctype/PRF combinations behave differently under FIPS.
- [ ] **Logon trigger**: the circuit breaker + race guard are shipped (§2), so the trigger is production-acceptable; choose **scheduler-only** if you want the login path fully decoupled from LDAP. Tune `c_breaker_threshold`/`c_breaker_cooldown` to your environment.
- [ ] **Treat `scripts/oracle/ad-sync-install.sql` as security-reviewed code** — changes go through the same review as an auth system.

---

## 8 · Linux client support (pointer)

This repo's client chapters target Windows + DBeaver. The same Oracle-side setup serves Linux clients (`sqlplus`, JDBC apps) with no server changes — the differences are all client-side: `/etc/krb5.conf`, `KRB5CCNAME` / KEYRING vs FILE ccache, `kinit` cadence, and `sqlnet.ora` on the client. The sibling `tableau_ad_oracle` repo covers the Linux verification path; a dedicated Linux-client appendix here is tracked as future work. Until then, the principles in [docs/06](06-windows-lsa-and-ccache.md) (ccache handling) translate directly — only the tooling names change.

---

## Cross-references

- [docs/16-cmu-19c-failure-mode.md](16-cmu-19c-failure-mode.md) — why not CMU
- [docs/17-external-users-and-ad-sync.md](17-external-users-and-ad-sync.md) — the mechanism
- [docs/19-ad-admin-runbook.md](19-ad-admin-runbook.md) — AD operations, `ktpass` flags, SPN rules
- [troubleshooting.md](../troubleshooting.md) — error reference + diagnostics matrix
- [RECIPE.md](../RECIPE.md) — deployed-state cheatsheet
