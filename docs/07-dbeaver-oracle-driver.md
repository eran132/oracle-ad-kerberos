# 07 · DBeaver Oracle JDBC driver

DBeaver ships an Oracle driver definition pre-registered, but **its default jar list is not sufficient for Kerberos**. The bundled `ojdbc8.jar` works fine for password auth; Kerberos additionally needs `oraclepki.jar` and the `osdt` jars. This chapter fixes that.

---

## 1. Which DBeaver edition

DBeaver **Community Edition** is enough — Kerberos auth is a property of the Oracle JDBC driver, not a DBeaver feature gate. Confirmed on DBeaver 23.x and 24.x.

If you don't have it: <https://dbeaver.io/download/> → "Windows (Installer)" → run installer with defaults.

## 2. Get the right jars

Download the **same version** of all four jars from Oracle. Mixing versions across these jars produces `NoSuchMethodError` at connect time.

Recommended version: **ojdbc8 23.3.0.23.09** (or current 23.x) — works with Oracle Database 19c and 21c.

> **Two version trains in play.** Oracle's JDBC driver (`ojdbc8`, `oraclepki`) and OSDT (`osdt_core`, `osdt_cert`) ship as separate Maven artifacts on independent version cadences. As of 2026-05 the matched pair is **ojdbc8 23.3.0.23.09 + osdt 21.9.0.0** — both pulled from Maven Central, both on the classpath of the same JVM. Don't try to force osdt to 23.x — that version doesn't exist on Maven Central.

Source — pick one:
- **Maven Central** (no login, no proxy headaches; used by this lab):
  - `https://repo1.maven.org/maven2/com/oracle/database/jdbc/ojdbc8/23.3.0.23.09/ojdbc8-23.3.0.23.09.jar`
  - `https://repo1.maven.org/maven2/com/oracle/database/security/oraclepki/23.3.0.23.09/oraclepki-23.3.0.23.09.jar`
  - `https://repo1.maven.org/maven2/com/oracle/database/security/osdt_core/21.9.0.0/osdt_core-21.9.0.0.jar`
  - `https://repo1.maven.org/maven2/com/oracle/database/security/osdt_cert/21.9.0.0/osdt_cert-21.9.0.0.jar`
- **Oracle's own portal** (requires Oracle SSO login): <https://www.oracle.com/database/technologies/appdev/jdbc-downloads.html> → Oracle Database 23ai JDBC Driver and UCP Downloads → "ojdbc8-full.tar.gz".

Required jars:

| Jar | Purpose |
|---|---|
| `ojdbc8.jar` | The JDBC driver itself |
| `oraclepki.jar` | Oracle PKI / wallet support — pulled in transitively by the Kerberos code path |
| `osdt_core.jar` | Oracle Security Developer Tools — core crypto |
| `osdt_cert.jar` | OSDT certificate handling |

Stage them anywhere stable — convention used by this lab:

```
C:\Users\<you>\jdbc\oracle\23.3\
  ├─ ojdbc8.jar
  ├─ oraclepki.jar
  ├─ osdt_core.jar
  └─ osdt_cert.jar
```

Don't put them inside the DBeaver install dir — auto-updates will wipe them.

## 3. Register the jars in DBeaver's driver definition

DBeaver → **Database menu → Driver Manager** → select **Oracle** → **Edit…** → **Libraries** tab.

You should see a list that includes `ojdbc8.jar` (downloaded automatically by DBeaver on first use). The problem: it is the **bundled** ojdbc8, often a different version than the companion jars you just downloaded.

Clean approach:

1. Select every existing entry → **Delete**. The driver list goes empty.
2. Click **Add File** four times — once for each of the four jars in `C:\Users\<you>\jdbc\oracle\23.3\`.
3. Click **Find Class** at the bottom — DBeaver scans the jars and lists driver classes. Pick `oracle.jdbc.OracleDriver`. The **Class Name** field at the top fills in automatically.
4. Confirm the **URL Template** is:
   ```
   jdbc:oracle:thin:@//{host}:{port}/{database}
   ```
   (Note the `//` and `/` — service-name syntax. SID syntax `jdbc:oracle:thin:@host:port:SID` does not work for the PDB.)
5. **OK** to close the dialog.

ASCII representation of the Libraries tab after the change:

```
+-- Edit Driver  [Oracle] ------------------------------------------+
| Settings | Libraries | Connection properties | Driver properties |
|                                                                  |
|   Library/Resource          Version    Path                      |
|   ------------------------------------------------------------   |
|   ojdbc8.jar                23.3.0.23  C:\...\jdbc\oracle\23.3   |
|   oraclepki.jar             23.3.0.23  C:\...\jdbc\oracle\23.3   |
|   osdt_core.jar             23.3.0.23  C:\...\jdbc\oracle\23.3   |
|   osdt_cert.jar             23.3.0.23  C:\...\jdbc\oracle\23.3   |
|                                                                  |
|   [ Add File ] [ Add Folder ] [ Delete ]   [ Find Class ]        |
|                                                                  |
|   Driver class: oracle.jdbc.OracleDriver                         |
|                                                              [OK]|
+------------------------------------------------------------------+
```

Real screenshot: see [../screenshots/README.md](../screenshots/README.md) item 01.

## 4. Verify Java sees the jars

A useful one-off sanity check from PowerShell, before fighting with DBeaver:

```powershell
PS> $jars = "C:\Users\<you>\jdbc\oracle\23.3\*.jar"
PS> & "$env:JAVA_HOME\bin\java" -cp ($jars -join ';') oracle.jdbc.OracleDriver
# (no output is good — class loaded; an exception means jars are missing or incompatible)
```

If you don't have a JDK on `PATH`, DBeaver bundles one at `<dbeaver-install>\jre\bin\java.exe`; use that instead.

## 5. Why the four-jar set is needed (vs. just `ojdbc8.jar`)

The Oracle JDBC thin driver code path for `KERBEROS5` calls into `oracle.security.o5logon` for GSSAPI setup. Those classes live in `oraclepki.jar` (which in turn depends on `osdt_core.jar` + `osdt_cert.jar`). Without them, the first Kerberos connection throws:

```
java.lang.NoClassDefFoundError: oracle/security/o5logon/O5LoginClientHelper
```

— which is the actionable "you forgot oraclepki" error. Some older guides recommend `ucp.jar` too; not needed for our connection style.

## 6. JVM args for DBeaver

The driver alone is not enough — the JVM hosting DBeaver also needs to know where `krb5.ini` lives and how to wire up GSSAPI. Those go in `dbeaver.ini`, covered in chapter [08](08-dbeaver-connection.md). The values are pre-baked in [../config/windows/dbeaver-jvm-args.example](../config/windows/dbeaver-jvm-args.example).

Next: [08 · DBeaver connection settings](08-dbeaver-connection.md).
