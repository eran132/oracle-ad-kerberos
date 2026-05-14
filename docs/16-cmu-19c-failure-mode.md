# 16 · Why this lab does NOT use Oracle CMU (and what it uses instead)

> tl;dr — On Oracle 19c (19.30) CMU + Kerberos + Active-Directory-group→shared-schema is broken in a way that only Oracle Support can explain. We exhausted the documented configuration space; same `ORA-28030` every time. Lab ships an `ad_sync` PL/SQL package as the working pattern. See chapter [17](17-external-users-and-ad-sync.md) for the working pattern.

This chapter documents the investigation so the next person doesn't have to redo it.

---

## What we tried to make work

> Goal: an AD user (e.g. `alice@MYLAB.LOCAL`) authenticates to Oracle 19c via Kerberos (no password). Oracle then looks the user up in AD via LDAPS-636, reads `memberOf`, finds `CN=oracle-readers,OU=Groups,DC=mylab,DC=local`, maps that AD-group DN to the GLOBAL Oracle user `ORA_READERS`, logs the AD user in as that shared schema. Everything controlled by the AD administrator; zero Oracle objects per AD user.

This is the canonical "CMU with Microsoft Active Directory" pattern in Oracle's own docs.

## What we configured (every documented prerequisite)

| Item | Value | Verified |
|---|---|---|
| AD svc account `svc-ora-ldap` | "Read properties" on user objects in `DC=mylab,DC=local` | ✅ `ldapsearch -D svc-ora-ldap ... '(sAMAccountName=alice)' memberOf` returns the right entry |
| AD CS Enterprise Root CA | `CN=mylab-root-ca,DC=mylab,DC=local` installed on `ad1` | ✅ ad1 presents AES-256 LDAPS cert chained to this CA |
| Oracle wallet | `/u01/app/oracle/cmu/wallet/`, auto-login (`cwallet.sso`), 0600 oracle:oinstall | ✅ |
| Wallet entries | `ORACLE.SECURITY.USERNAME`, `ORACLE.SECURITY.DN`, `ORACLE.SECURITY.PASSWORD` per [official docs](https://docs.oracle.com/en/database/oracle/oracle-database/19/dbseg/integrating_mads_with_oracle_database.html) | ✅ Listed by `mkstore -wrl ... -list` |
| Wallet trust anchor | `CN=mylab-root-ca,DC=mylab,DC=local` as `-trusted_cert` | ✅ `orapki wallet display` confirms |
| `dsi.ora` (NOT `ldap.ora`) | `DSI_DIRECTORY_SERVERS = (ad1.mylab.local:389:636)`, `DSI_DIRECTORY_SERVER_TYPE = AD`, `DSI_DEFAULT_ADMIN_CONTEXT = "DC=mylab,DC=local"` | ✅ — `ldap.ora` renamed to `ldap.ora.disabled` per the Oracle doc note **"Only use dsi.ora to configure CMU-Active Directory"** |
| `sqlnet.ora` | `WALLET_LOCATION = ...` only; nothing else CMU-specific | ✅ |
| `LDAP_DIRECTORY_ACCESS` | `PASSWORD` at CDB and PDB level, `SCOPE=BOTH` | ✅ confirmed after instance bounce |
| `LDAP_DIRECTORY_SYSAUTH` | `YES`, `SCOPE=SPFILE`, instance bounced | ✅ confirmed after bounce |
| GLOBAL Oracle users | `CREATE USER ora_readers IDENTIFIED GLOBALLY AS 'CN=oracle-readers,OU=Groups,DC=mylab,DC=local'` (and `ora_writers` similarly) | ✅ rows present in `DBA_USERS` with `AUTHENTICATION_TYPE = GLOBAL` and matching `EXTERNAL_NAME` |
| Alice's AD record | `userPrincipalName = alice@MYLAB.LOCAL`, `memberOf` contains `CN=oracle-readers,OU=Groups,DC=mylab,DC=local` | ✅ |
| End-to-end LDAPS reachable from Oracle | PL/SQL `DBMS_LDAP.init` → `open_ssl(wallet)` → `simple_bind_s(svc-ora-ldap, pwd)` → `search_s('(userPrincipalName=alice@MYLAB.LOCAL)')` returns alice's DN + memberOf | ✅ rc=0 across the board |
| SELinux | Tested both enforcing and permissive | Same failure either way |
| firewalld | Stopped during a test run | Same failure |
| `/etc/resolv.conf` | Trimmed to `ad1.mylab.local` only (no corporate forwarders) | Same failure |

## What broke

Every documented permutation returns `ORA-28030: Server encountered problems accessing LDAP directory service`.

Captured network behaviour on the Oracle side during alice's auth attempt:

```
12:12:04.153  ora01 → ad1:636   SYN
12:12:04.154  ad1   → ora01     SYN/ACK
12:12:04.154  ora01 → ad1       ACK             ← TCP established
12:12:04.160  ora01 → ad1       FIN             ← 6 ms later, Oracle closes, NO TLS Client Hello
12:12:04.160  ad1   → ora01     ACK
12:12:04.161  ad1   → ora01     RST
                              ... 1 s ...
ORA-28030 returned to the client
```

That 6 ms is too fast to be a TLS handshake. Oracle's NTZ (TLS library) fails an internal precondition before sending Client Hello. The 1-second silence afterward is Oracle's CMU code waiting on some internal timer/retry, then giving up.

The `sqlnet.ora` `TRACE_LEVEL_SERVER = SUPPORT` server trace shows the wallet is read successfully (both `ewallet.p12` and `cwallet.sso`), `ssl.renegotiate` parameter is queried, and then the 1-second silence and the `ORA-28030` is emitted. No useful internal error.

A `DBMS_LDAP.open_ssl` from PL/SQL against the **same wallet, same trust anchor, same port 636, same bind credentials** succeeds. So the wallet, cert chain, network path, and AD service account are all proven good in isolation — it is only the CMU code path inside `kzn*`/`ntz*` that fails.

## Why we believe this is an Oracle 19c bug or undocumented prerequisite

- Documented config is correct (cross-checked against [docs.oracle.com 19c CMU section](https://docs.oracle.com/en/database/oracle/oracle-database/19/dbseg/integrating_mads_with_oracle_database.html)).
- DBMS_LDAP from PL/SQL works on the same wallet → wallet OK.
- `ldapsearch` from the OS works → AD service-account permissions OK.
- TCP connect to ad1:636 happens → there is no firewall / DNS / SELinux block.
- Failure is silent inside the database's `ntz` (TLS) layer — never visible to user-mode trace.
- Pattern is consistent with public reports of Oracle 19c CMU+Kerberos requiring specific patch sets that are not documented in the security guide.

23ai changes this code path substantially. Anyone re-investigating should consider that the proper resolution is "open an Oracle Support SR" — not "more debugging on 19c."

## What the lab ships instead

Chapter [17 — External users + AD-driven sync](17-external-users-and-ad-sync.md) describes the working pattern in detail:

1. Each AD member of `oracle-readers` / `oracle-writers` is materialised as an Oracle **EXTERNAL** user (e.g. `"ALICE@MYLAB.LOCAL" IDENTIFIED EXTERNALLY`).
2. AD groups map to **Oracle roles** (`ORA_READERS_ROLE`, `ORA_WRITERS_ROLE`) with the privileges the DBA wants.
3. A small PL/SQL package `AD_SYNC.AD_SYNC` reads AD group membership over LDAPS-636 using the **same wallet** built for the failed CMU attempt, and reconciles Oracle role grants to match.
4. The package runs both on a `DBMS_SCHEDULER` 10-minute schedule **and** in an `AFTER LOGON` trigger so each connect picks up the latest AD state with zero lag.

Net behaviour for an end user is identical to CMU: log in with Kerberos, get roles based on AD group membership, no Oracle password. The only behavioural delta is the cron-style lag (mitigated by the JIT trigger) and a one-time `CREATE USER` per AD user (mitigated by the sync auto-creating them).

## Reading order from here

- [docs/17-external-users-and-ad-sync.md](17-external-users-and-ad-sync.md) — the working pattern, end-to-end
- [troubleshooting.md#ora-28030](../troubleshooting.md#ora-28030) — short version of this chapter linked from error tables
