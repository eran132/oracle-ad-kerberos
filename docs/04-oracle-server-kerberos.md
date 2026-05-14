# 04 · Oracle server-side Kerberos configuration — recap

What [..\..\..\tableau_ad_oracle\scripts\oracle21c-kerberos.sh](../../tableau_ad_oracle/scripts/oracle21c-kerberos.sh) did on `ora01`, and what each setting means.

---

## 1. `krb5.conf` on the Linux side

Template: [..\..\..\tableau_ad_oracle\config\krb5.conf.example](../../tableau_ad_oracle/config/krb5.conf.example), installed at `/etc/krb5.conf`. Same content as the Windows `krb5.ini` ([../config/windows/krb5.ini.example](../config/windows/krb5.ini.example)).

The Oracle process reads this through `SQLNET.KERBEROS5_CONF` in `sqlnet.ora` — but `realm-join.sh` also relies on `/etc/krb5.conf` for `sssd` and `kinit` at the OS level. Keeping them at one path avoids double-maintenance.

## 2. `sqlnet.ora`

Path: `$ORACLE_HOME/network/admin/sqlnet.ora` (typically `/u01/app/oracle/product/19.0.0/dbhome_1/network/admin/sqlnet.ora` for 19c, or `/u01/app/oracle/product/21.0.0/dbhome_1/network/admin/sqlnet.ora` for 21c).

Content ([..\..\..\tableau_ad_oracle\config\oracle-sqlnet.ora.example](../../tableau_ad_oracle/config/oracle-sqlnet.ora.example)):

```
SQLNET.AUTHENTICATION_SERVICES = (BEQ, KERBEROS5)
SQLNET.KERBEROS5_CONF = /etc/krb5.conf
SQLNET.KERBEROS5_CONF_MIT = TRUE
SQLNET.KERBEROS5_KEYTAB = /etc/oracle/keytabs/ora01.keytab
SQLNET.FALLBACK_AUTHENTICATION = FALSE
SQLNET.AUTHENTICATION_KERBEROS5_SERVICE = oracle
```

> **Do not set `SQLNET.KERBEROS5_CC_NAME = /tmp/krb5cc_%{uid}`.** Oracle's sqlnet parser does **not** substitute `%{uid}` — that's a libkrb5/sssd syntax. With this line set, sqlnet looks for a file named *literally* `/tmp/krb5cc_%{uid}` and the Kerberos adapter init fails. Leave it unset; the server doesn't need a client ccache (it has the keytab). See [troubleshooting.md#ora-12641](../troubleshooting.md#ora-12641).

Line by line:

| Setting | Effect |
|---|---|
| `SQLNET.AUTHENTICATION_SERVICES = (KERBEROS5)` | The listener accepts only Kerberos auth. Add `BEQ` if you also want local OS-level auth (`sqlplus / as sysdba` from the `oracle` user); we do not in this lab. |
| `SQLNET.KERBEROS5_CONF` | Tells Oracle where its krb5.conf is — Oracle's GSSAPI is built-in, doesn't use the OS one by default. |
| `SQLNET.KERBEROS5_CONF_MIT = TRUE` | Parses the krb5.conf in MIT format (as opposed to Heimdal or legacy Oracle format). |
| `SQLNET.KERBEROS5_KEYTAB` | Path to the keytab the listener will use to decrypt AP-REQ. Must be readable by the OS user running the listener (oracle). |
| `SQLNET.KERBEROS5_CC_NAME` | Where the **server side** caches tickets when it makes outbound calls (e.g., proxy auth). Not relevant for inbound DBeaver auth, but harmless. |
| `SQLNET.FALLBACK_AUTHENTICATION = FALSE` | If Kerberos auth fails, **do not** fall back to password prompt. Forces all logins through Kerberos. Useful as a security guarantee in production; toggle to TRUE temporarily if you need to debug a stuck Kerberos config with `sqlplus alice/<pw>@orclpdb1`. |

After changing `sqlnet.ora`, restart the listener:

```bash
[ora01]$ sudo -u oracle lsnrctl reload   # or stop/start
```

## 3. `OS_AUTHENT_PREFIX`

Set in the PDB (`orclpdb1`):

```sql
ALTER SYSTEM SET OS_AUTHENT_PREFIX='' SCOPE=SPFILE;
SHUTDOWN IMMEDIATE; STARTUP;
```

Default is `OPS$`. With the default, an external user must be created as `CREATE USER "OPS$ALICE@MYLAB.LOCAL" IDENTIFIED EXTERNALLY` and connecting as `alice@MYLAB.LOCAL` matches the prefixed name. Setting it to empty string makes the external username the Kerberos principal verbatim, which is what every modern guide assumes.

`REMOTE_OS_AUTHENT` does **not** apply: it was removed in Oracle 12c. Old docs that tell you to set `REMOTE_OS_AUTHENT=TRUE` are obsolete.

## 4. Externally identified users

For each AD user that should be able to connect:

```sql
CREATE USER "ALICE@MYLAB.LOCAL" IDENTIFIED EXTERNALLY;
GRANT CREATE SESSION TO "ALICE@MYLAB.LOCAL";
-- Then whatever role/object privileges they actually need.
GRANT CONNECT TO "ALICE@MYLAB.LOCAL";
```

Notes on naming:
- The **double quotes** are mandatory because the name contains `@`.
- The case **inside the quotes is preserved**: Oracle stores the username as `ALICE@MYLAB.LOCAL` (upper-case) — the canonical form when the client realm in the Kerberos ticket is `MYLAB.LOCAL` (upper-case).
- If the client realm in the ticket is somehow lower-case (`alice@mylab.local`), Oracle will not match — see [troubleshooting.md#gss-defective-token](../troubleshooting.md#gss-defective-token).

## 5. Confirming the user setup

In SQL\*Plus or DBeaver after a successful Kerberos connect:

```sql
SELECT USERNAME, EXTERNAL_NAME, AUTHENTICATION_TYPE
  FROM DBA_USERS
 WHERE USERNAME LIKE '%@MYLAB.LOCAL';
```

Expected:
```
USERNAME            EXTERNAL_NAME       AUTHENTICATION_TYPE
ALICE@MYLAB.LOCAL                       EXTERNAL
BOB@MYLAB.LOCAL                         EXTERNAL
CAROL@MYLAB.LOCAL                       EXTERNAL
```

`AUTHENTICATION_TYPE = EXTERNAL` means OS / Kerberos. (`PASSWORD` would mean classic native, `GLOBAL` would mean enterprise directory — neither for us.)

## 6. The listener

The listener (`tnslsnr`) does **not** need any Kerberos-specific config — `sqlnet.ora` is read by the database side of the connection, after the listener has already handed off the socket. So `listener.ora` is whatever Oracle's `dbca` produced; this lab uses the default static configuration.

To convince yourself the listener is happy:

```bash
[ora01]$ sudo -u oracle lsnrctl status
Service "orclpdb1" has 1 instance(s).
  Instance "orcl", status READY, has 1 handler(s) for this service...
```

`SERVICE_NAME=orclpdb1` is what DBeaver uses; [docs/08](08-dbeaver-connection.md) section 2.

## 7. Server-side verification scripts

Before relying on the client side, prove on the Oracle host itself:

```bash
[ora01]$ /home/vagrant/scripts/keytab-check.sh
# klist -kte the keytab, kinit -k as the service principal, kvno self-reach
[ora01]$ /home/vagrant/scripts/user-oracle-ticket-check.sh alice
# password-based kinit alice@MYLAB.LOCAL, kvno oracle/ora01..., sqlplus /@ORCLPDB1
```

Both must pass before any Windows-side work makes sense. If `keytab-check.sh` fails:
- Keytab missing or wrong perms → re-run keytab deployment ([03 section: keytab](03-ad-and-spn-setup.md)).
- `kinit -k` failure with "Decrypt integrity check failed" → keytab/AD drift → re-run `ktpass-keytabs.ps1` and redeploy ([troubleshooting.md#krb-ap-err-modified](../troubleshooting.md#krb-ap-err-modified)).

If `user-oracle-ticket-check.sh` fails:
- `sqlplus` step gets `ORA-12631` → `sqlnet.ora` not loaded → check `$ORACLE_HOME/network/admin/sqlnet.ora` path and listener reload.
- `sqlplus` step gets `ORA-01017: invalid username/password` → user not created externally, or `OS_AUTHENT_PREFIX` is still `OPS$`.

## Next

Server side is now fully recapped. Continue to [05 · Windows client](05-windows-client-mit-krb.md) if you skipped ahead earlier.
