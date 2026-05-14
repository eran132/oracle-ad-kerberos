# 08 · DBeaver connection settings

You have MIT KfW installed, `krb5.ini` in place, a fresh TGT in your file ccache, and the four Oracle jars registered. This chapter creates the actual DBeaver connection.

---

## 1. Add JVM arguments to `dbeaver.ini`

DBeaver reads JVM arguments from `dbeaver.ini` next to `dbeaver.exe`. Where it lives depends on how DBeaver was installed:

| Install method | `dbeaver.ini` path | Admin needed to edit? |
|---|---|---|
| Winget (per-user, this lab's method) | `C:\Users\<you>\AppData\Local\DBeaver\dbeaver.ini` | No |
| Manual NSIS installer (system-wide) | `C:\Program Files\DBeaver\dbeaver.ini` | Yes — Program Files is write-protected |

Open it in an editor (run as Administrator if it's under Program Files). Find the line `-vmargs` — every line below it is a JVM argument. Insert the contents of [../config/windows/dbeaver-jvm-args.example](../config/windows/dbeaver-jvm-args.example) **immediately after** the `-vmargs` line (before the other `-D` and `--add-opens` lines):

```
-Djava.security.krb5.conf=C:\ProgramData\MIT\Kerberos5\krb5.ini
-Djavax.security.auth.useSubjectCredsOnly=false
-Dsun.security.krb5.debug=false
-Dsun.security.jgss.debug=false
```

ASCII view of what `dbeaver.ini` should look like (relevant lines only):

```
-startup
plugins/org.eclipse.equinox.launcher_1.x.x.jar
...
-vmargs
-XX:+UseG1GC
-Xms256m
-Xmx2048m
-Djava.security.krb5.conf=C:\ProgramData\MIT\Kerberos5\krb5.ini
-Djavax.security.auth.useSubjectCredsOnly=false
-Dsun.security.krb5.debug=false
-Dsun.security.jgss.debug=false
```

While **troubleshooting** flip the debug flags to `true`, restart DBeaver, reproduce the failure, then flip them back. Output appears in DBeaver's launch console (visible if you start DBeaver from a PowerShell window: `& "C:\Program Files\DBeaver\dbeaver.exe"`).

> `KRB5CCNAME` is **not** an `-D` property. It must be a real environment variable, set per chapter [06](06-windows-lsa-and-ccache.md). Don't try to set it inside `dbeaver.ini`.

Close DBeaver fully before reopening so the new args take effect.

## 2. New connection — Main tab

DBeaver → **Database menu → New Database Connection** → **Oracle** → **Next**.

Field by field:

| Field | Value |
|---|---|
| Connect by | **Service Name** *(radio button)* |
| Host | `ora01.mylab.local` |
| Port | `1521` |
| Database / Service | `orclpdb1` |
| Authentication | `Database Native` *(yes — leave this alone; the Kerberos selector is **off** by design, see note below)* |
| Username | *(leave blank)* |
| Password | *(leave blank)* |
| Save password | unchecked |

ASCII representation:

```
+-- Connect to a database  [Oracle] -------------------------------+
| Main | Driver properties | SSH | Proxy | ...                     |
|                                                                  |
|   Connect by:   (o) Service Name    ( ) SID    ( ) TNS           |
|                                                                  |
|   Host:        [ ora01.mylab.local                          ]    |
|   Port:        [ 1521 ]                                          |
|   Database:    [ orclpdb1                                    ]   |
|                                                                  |
|   Authentication:  [ Database Native              v ]            |
|   Username:    [                                           ]     |
|   Password:    [                                           ]     |
|   [ ] Save password                                              |
|                                                                  |
|   [ Test Connection... ]              [ Cancel ] [ Finish ]      |
+------------------------------------------------------------------+
```

Why **Database Native** and not "Kerberos": DBeaver's "Kerberos" auth dropdown is meant for drivers that take a `principal` field and call into JAAS themselves. The Oracle JDBC thin driver does **not** want that — it does Kerberos via the driver property `oracle.net.authentication_services=(KERBEROS5)` and gets the principal from the ccache. So leaving auth as "Database Native" with **blank credentials** is the configuration that actually works.

Real screenshot: see [../screenshots/README.md](../screenshots/README.md) item 02.

## 3. Driver properties tab

Switch to the **Driver properties** tab in the same dialog. Add these two properties (right-click → New / Add) — values exactly as shown:

| Property | Value |
|---|---|
| `oracle.net.authentication_services` | `(KERBEROS5)` |
| `oracle.net.kerberos5_mutual_authentication` | `true` |

ASCII:

```
+-- Connect to a database  [Oracle] -------------------------------+
| Main | Driver properties | SSH | Proxy | ...                     |
|                                                                  |
|   Name                                       Value               |
|   ----------------------------------------- --------------       |
|   oracle.net.authentication_services        (KERBEROS5)          |
|   oracle.net.kerberos5_mutual_authentication true                |
|                                                                  |
|   [ Add ]  [ Remove ]                                            |
|                                                                  |
|   [ Test Connection... ]              [ Cancel ] [ Finish ]      |
+------------------------------------------------------------------+
```

Real screenshot: see [../screenshots/README.md](../screenshots/README.md) item 03.

The literal parentheses in `(KERBEROS5)` matter — Oracle parses the value as a SQL*Net list.

## 4. Test the connection

**Pre-requisite:** a valid TGT in your ccache.

```powershell
PS> klist | Select-String "Default principal"
Default principal: alice@MYLAB.LOCAL
PS> klist | Select-String "krbtgt"
05/13/2026 09:14:02  05/13/2026 19:14:02  krbtgt/MYLAB.LOCAL@MYLAB.LOCAL
```

Now in DBeaver, click **Test Connection…**. Expected result:

```
+------------------------------------------+
|  Success                                 |
|                                          |
|  Server: Oracle Database 19c Enterprise  |
|         Edition Release 19.0.0.0.0       |
|  Driver: Oracle JDBC driver  23.3.0.23.09|
|                                          |
|                              [   OK   ]  |
+------------------------------------------+
```

Click **Finish** to save the connection. Open a SQL editor on it and run:

```sql
SELECT USER, SYS_CONTEXT('USERENV', 'AUTHENTICATION_METHOD') FROM DUAL;
```

Expected output:

| USER | SYS_CONTEXT |
|---|---|
| `ALICE@MYLAB.LOCAL` | `KERBEROS` |

If `AUTHENTICATION_METHOD` is `PASSWORD` you slipped back into native auth — re-check the Driver properties tab (the most common cause: properties were added but not saved before Test).

Real screenshot: see [../screenshots/README.md](../screenshots/README.md) items 04 (test success) and 05 (SELECT USER).

## 5. Common first-time failures

- **`ORA-12631: NO_CRED_RECEIVED`** — JVM couldn't find your ticket. Either `KRB5CCNAME` is not visible to DBeaver, or `useSubjectCredsOnly` is the default `true`. See [troubleshooting.md#ora-12638](../troubleshooting.md#ora-12638) (yes, the error code there is the right anchor).
- **`KrbException: Identifier doesn't match expected value (906)`** — enctype mismatch. See [troubleshooting.md#enctype-mismatch](../troubleshooting.md#enctype-mismatch).
- **`GSS-API: Defective token detected`** — almost always wrong realm casing somewhere. The Kerberos protocol is case-sensitive on realm names; `mylab.local` and `MYLAB.LOCAL` are different. See [troubleshooting.md#gss-defective-token](../troubleshooting.md#gss-defective-token).

When in doubt, flip `-Dsun.security.krb5.debug=true` in `dbeaver.ini`, restart DBeaver from a PowerShell window, click Test, and watch the AS/TGS exchange in stdout. The line that says `KrbAsRep: ...` or `KrbApReq.authenticate: ...` usually tells you exactly what failed.

Next: [09 · End-to-end verification](09-verification-end-to-end.md).
