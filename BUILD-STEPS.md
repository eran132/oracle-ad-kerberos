# BUILD-STEPS — numbered execution order, per component

> Sequential checklist for building the full AD → Oracle → DBeaver Kerberos stack from scratch. Each step says **which machine** to run it on, **what** to run, and **what success looks like**. The numbered `docs/*` chapters explain *why* each step is there; this file is the *do this next* operational thread.

Components and the user/account to run as:

| Tag | Machine | Run as |
|---|---|---|
| **[AD]** | `ad1.mylab.local` (Windows Server 2022 DC) | Domain Admin in elevated PowerShell |
| **[ORA]** | `ora01.mylab.local` (RHEL 9, Oracle 19c) | Linux user with `sudo`; SQL as Oracle DBA via `sqlplus / as sysdba` |
| **[WKS]** | `wks01.mylab.local` (Win11 client, domain-joined) | `MYLAB\Administrator` for setup, `MYLAB\alice` for testing |

Lab placeholders to search-replace for a real environment: `MYLAB.LOCAL` / `mylab.local`, `ad1.mylab.local`, `ora01.mylab.local`, `wks01.mylab.local`, group names `oracle-readers` / `oracle-writers`, test users `alice` / `bob` / `carol`.

---

## Phase 0 · Prerequisites

1. **[AD]** Windows Server 2022 DC promoted, forest `mylab.local`, DNS role installed, A-records for `ad1`, `ora01`, `wks01`. Time service authoritative.
2. **[AD]** AD Certificate Services (Enterprise Root CA, name `mylab-root-ca`) installed: `Add-WindowsFeature ADCS-Cert-Authority` + `Install-AdcsCertificationAuthority -CAType EnterpriseRootCA`. Confirm the DC has auto-enrolled an LDAPS cert: `certutil -store My` on the DC should list a cert with subject `CN=ad1.mylab.local`.
3. **[ORA]** RHEL 9 host with Oracle 19c (19.30+) Enterprise Edition installed, CDB `ORCLCDB` open, PDB `ORCLPDB1` open `READ WRITE`. Listener on 1521 reachable from clients.
4. **[ALL]** All three hosts in the same routable network (lab uses VirtualBox host-only `192.168.56.0/24`). Verify with `Test-NetConnection ad1.mylab.local -Port 88,389,636,464` from `wks01`, and `nc -zv ad1.mylab.local 88 389 636 464` from `ora01`. All four ports must return open.
5. **[ALL]** Clock skew between every pair of hosts < 300 seconds. On `ad1`: authoritative time source. On `ora01`: `chronyd` peering with `ad1.mylab.local`. On `wks01`: w32time syncing to the domain.

---

## Phase 1 · AD setup (on `ad1`)

> Full PowerShell snippets in [docs/19-ad-admin-runbook.md](docs/19-ad-admin-runbook.md). Single-page ticket version in [AD-SETUP-TICKET.md](AD-SETUP-TICKET.md).

6. **[AD]** Create `svc-ora01` service account with a **throwaway** password (it's only a placeholder — AD won't create an enabled account without one; step 7's `ktpass` resets it to the value that counts). `New-ADUser -Name svc-ora01 -UserPrincipalName svc-ora01@MYLAB.LOCAL -AccountPassword <random> -Enabled $true -PasswordNeverExpires $true ...` then `Set-ADUser -KerberosEncryptionType AES256`. **If it already exists** (rebuild/fix): skip `New-ADUser`, just `Enable-ADAccount` + `Set-ADUser -KerberosEncryptionType AES256` (idempotent guard shown in [docs/19 §A1](docs/19-ad-admin-runbook.md)).
   - **Success:** `Get-ADUser svc-ora01` returns; `msDS-SupportedEncryptionTypes` = 16.

7. **[AD]** Register the Oracle SPN and emit the keytab in one shot with `ktpass`. Use **`-pass *`** so it prompts (hidden) — this is the **authoritative** password; **record it in your password vault** (the next keytab rotation needs account + keytab to agree):
   ```powershell
   ktpass -princ oracle/ora01.mylab.local@MYLAB.LOCAL -mapuser MYLAB\svc-ora01 `
          -pass * -crypto AES256-SHA1 -ptype KRB5_NT_PRINCIPAL `
          -out C:\temp\ora01.keytab
   ```
   The two flags people get wrong: **`-crypto AES256-SHA1`** = derive only the AES256 (etype 18) key into the keytab — must match the account's `msDS-SupportedEncryptionTypes` (=16), `sqlnet.ora`, and the client `krb5.ini`; never use `All` (ships a weak RC4 key). **`-ptype KRB5_NT_PRINCIPAL`** = standards-compliant principal name-type that Oracle/MIT/Java expect; other types cause name-type mismatches that fail auth. Full table + AES verification in [docs/19 §A2](docs/19-ad-admin-runbook.md).

   `ktpass` **always** resets the password and bumps the KVNO — that's how it derives the keytab key. **If the account/SPN already exist or this is a rotation**, running this exact command is correct: create and rotate converge here, there is no separate "update" command. Only special case: a **duplicate SPN** — if the verify below shows >1 account or the wrong one, `setspn -D oracle/ora01.mylab.local <WRONG-account>` for each wrong holder, then re-run the `ktpass` above. After generating, **verify the keytab is actually AES256** (`ktab -l -e -t -k` / `klist -kte` shows etype 18) and `Get-ADUser svc-ora01 -Properties msDS-SupportedEncryptionTypes` returns 16 — `Set-ADUser -KerberosEncryptionType AES256` alone does not guarantee RC4 is refused unless domain policy agrees.
   - **Success:** `setspn -Q oracle/ora01.mylab.local` returns **exactly one** account (`CN=svc-ora01,...`). `setspn -X` reports zero duplicates.

8. **[AD]** Create `svc-ora-ldap` service account (Oracle binds to AD over LDAPS with it for group lookups). Default `Domain Users` privileges are sufficient. Unlike `svc-ora01` this account has **no keytab** — its password is used directly by Oracle (loaded into the wallet in step 18), so the password set here **is authoritative**; record it and hand it to the DBA out-of-band. **If it already exists**: leave the password untouched (changing it without updating the wallet breaks the sync — that's the Part B3 rotation procedure, not a re-run; idempotent guard in [docs/19 §A3](docs/19-ad-admin-runbook.md)).
   ```powershell
   if (-not (Get-ADUser -Filter "SamAccountName -eq 'svc-ora-ldap'" -ErrorAction SilentlyContinue)) {
     $pw = Read-Host -AsSecureString "NEW password for svc-ora-ldap (vault; give to DBA)"
     New-ADUser -Name svc-ora-ldap -SamAccountName svc-ora-ldap `
       -UserPrincipalName svc-ora-ldap@MYLAB.LOCAL -AccountPassword $pw `
       -Enabled $true -PasswordNeverExpires $true -CannotChangePassword $true `
       -Path "CN=Users,DC=mylab,DC=local"
   } else { Write-Host "exists - leaving password untouched (rotate via Part B3)" }
   ```
   - **Success:** `Get-ADUser svc-ora-ldap` returns enabled.

9. **[AD]** Create the OU and groups: `OU=Groups,DC=mylab,DC=local` containing `oracle-readers` and `oracle-writers` (both Global Security groups). Idempotent — safe to re-run (`New-ADGroup`/`New-ADOrganizationalUnit` error harmlessly if the object already exists; guard the OU as shown).
   ```powershell
   if (-not (Get-ADOrganizationalUnit -Filter 'Name -eq "Groups"' `
             -SearchBase "DC=mylab,DC=local" -ErrorAction SilentlyContinue)) {
     New-ADOrganizationalUnit -Name "Groups" -Path "DC=mylab,DC=local"
   }
   New-ADGroup -Name oracle-readers -GroupScope Global -GroupCategory Security `
     -Path "OU=Groups,DC=mylab,DC=local" -Description "Members get SELECT on ORCLPDB1"
   New-ADGroup -Name oracle-writers -GroupScope Global -GroupCategory Security `
     -Path "OU=Groups,DC=mylab,DC=local" -Description "Members get DML on ORCLPDB1"
   ```
   - **Success:** `Get-ADGroup oracle-readers` and `Get-ADGroup oracle-writers` both return.

10. **[AD]** Add the test users to the groups (assumes `alice`, `bob`, `carol` already exist as normal AD users with `UserPrincipalName` set):
    ```powershell
    Add-ADGroupMember -Identity oracle-readers -Members alice, carol
    Add-ADGroupMember -Identity oracle-writers -Members bob
    ```
    - **Success:** `Get-ADGroupMember oracle-readers` lists alice + carol; `Get-ADGroupMember oracle-writers` lists bob.

11. **[AD]** Export the Root CA cert so the Oracle wallet can trust the LDAPS cert chain:
    ```powershell
    (Get-CACertificate).RawData | Set-Content -Encoding Byte C:\temp\mylab-root-ca.cer
    certutil -encode C:\temp\mylab-root-ca.cer C:\temp\mylab-root-ca.pem
    ```
    - **Success:** `C:\temp\mylab-root-ca.pem` exists and `openssl x509 -in mylab-root-ca.pem -noout -subject` (on any host) shows `Subject = CN=mylab-root-ca,...`.

12. **[AD → ORA]** Securely ship `ora01.keytab` and `mylab-root-ca.pem` to `ora01`. (SCP, signed-email attachment, internal file share — your secure transfer mechanism.) **Delete from `C:\temp\` on the DC after transfer.**

---

## Phase 2 · Oracle server setup (on `ora01`)

> Detailed narrative in [docs/04-oracle-server-kerberos.md](docs/04-oracle-server-kerberos.md) and [docs/11-ldaps-cert-trust.md](docs/11-ldaps-cert-trust.md).

13. **[ORA]** `/etc/hosts` has both addresses (so AD-side DNS hiccups don't take the connection down): `192.168.56.10 ad1.mylab.local ad1` and `192.168.56.20 ora01.mylab.local ora01`.

14. **[ORA]** Trust the Root CA at the OS level:
    ```bash
    sudo cp mylab-root-ca.pem /etc/pki/ca-trust/source/anchors/
    sudo update-ca-trust extract
    ```
    - **Success:** `openssl s_client -connect ad1.mylab.local:636 -verify_return_error </dev/null 2>&1 | grep -E "Verify return code|subject"` returns `Verify return code: 0 (ok)`.

15. **[ORA]** Install the keytab:
    ```bash
    sudo install -m 0640 -o oracle -g oinstall ora01.keytab /etc/oracle/keytabs/ora01.keytab
    sudo -u oracle klist -kte /etc/oracle/keytabs/ora01.keytab
    ```
    - **Success:** one entry, principal `oracle/ora01.mylab.local@MYLAB.LOCAL`, encryption type `aes256-cts-hmac-sha1-96`, KVNO ≥ 2.

16. **[ORA]** Write `/etc/krb5.conf` with realm `MYLAB.LOCAL`, KDC `ad1.mylab.local`. Smoke-test:
    ```bash
    sudo -u oracle kinit -kt /etc/oracle/keytabs/ora01.keytab oracle/ora01.mylab.local
    sudo -u oracle klist
    ```
    - **Success:** TGT for `oracle/ora01.mylab.local@MYLAB.LOCAL` valid for ~10 hours.

17. **[ORA]** Configure `$ORACLE_HOME/network/admin/sqlnet.ora` — exact contents in [RECIPE.md §2b](RECIPE.md):
    ```
    SQLNET.AUTHENTICATION_SERVICES = (BEQ, KERBEROS5)
    SQLNET.KERBEROS5_CONF = /etc/krb5.conf
    SQLNET.KERBEROS5_CONF_MIT = TRUE
    SQLNET.KERBEROS5_KEYTAB = /etc/oracle/keytabs/ora01.keytab
    SQLNET.FALLBACK_AUTHENTICATION = FALSE
    SQLNET.AUTHENTICATION_KERBEROS5_SERVICE = oracle
    WALLET_LOCATION = (SOURCE = (METHOD = FILE) (METHOD_DATA = (DIRECTORY = /u01/app/oracle/cmu/wallet)))
    ```
    > **Do not set `SQLNET.KERBEROS5_CC_NAME = .../krb5cc_%{uid}`** — Oracle does not substitute `%{uid}`. Omit the line entirely.

18. **[ORA]** Build the Oracle wallet at `/u01/app/oracle/cmu/wallet/`:
    ```bash
    sudo -u oracle bash -c '
      WD=/u01/app/oracle/cmu/wallet; PW="<wallet password>"
      orapki wallet create -wallet $WD -pwd "$PW"
      orapki wallet add    -wallet $WD -pwd "$PW" -trusted_cert -cert /etc/pki/ca-trust/source/anchors/mylab-root-ca.pem
      printf "%s\n" "$PW" | mkstore -wrl $WD -createEntry ORACLE.SECURITY.USERNAME svc-ora-ldap
      printf "%s\n" "$PW" | mkstore -wrl $WD -createEntry ORACLE.SECURITY.DN       "CN=svc-ora-ldap,CN=Users,DC=mylab,DC=local"
      printf "%s\n" "$PW" | mkstore -wrl $WD -createEntry ORACLE.SECURITY.PASSWORD "<svc-ora-ldap AD password>"
      orapki wallet create -wallet $WD -pwd "$PW" -auto_login
      chown -R oracle:oinstall $WD ; chmod 700 $WD ; chmod 600 $WD/*
    '
    ```
    - **Success:** `ls /u01/app/oracle/cmu/wallet/` shows `cwallet.sso` and `ewallet.p12` both owned `oracle:oinstall`, 0600.

19. **[ORA]** Validate the wallet end-to-end by exercising the same LDAPS bind path the package will use (DBMS_LDAP from PL/SQL):
    ```bash
    sudo -u oracle sqlplus -S / as sysdba <<'SQL'
    SET SERVEROUTPUT ON
    DECLARE s DBMS_LDAP.session; r PLS_INTEGER;
    BEGIN
      DBMS_LDAP.use_exception := TRUE;
      s := DBMS_LDAP.init('ad1.mylab.local', 636);
      r := DBMS_LDAP.open_ssl(s, 'file:/u01/app/oracle/cmu/wallet', NULL, 2);
      r := DBMS_LDAP.simple_bind_s(s, 'svc-ora-ldap@MYLAB.LOCAL', '<svc-ora-ldap AD password>');
      DBMS_OUTPUT.PUT_LINE('TLS+bind OK');
      r := DBMS_LDAP.unbind_s(s);
    END;
    /
    SQL
    ```
    - **Success:** prints `TLS+bind OK` with no PL/SQL errors. If this fails, fix the wallet before going further — the sync package will fail the same way.

20. **[ORA]** Clone this repo onto `ora01`. Create `.env` from `.env.example` and populate the real LDAP bind password:
    ```bash
    cp .env.example .env
    chmod 600 .env
    # edit .env, set LDAP_BIND_PWD=<the real svc-ora-ldap password>
    ```
    - **Success:** `.env` is 0600, owned by your build user, contains the real password.

21. **[ORA]** Install the AD-sync package + scheduler + trigger by running the wrapper (which sources `.env`):
    ```bash
    sudo -u oracle bash scripts/oracle/run-ad-sync-install.sh
    ```
    The installer also runs the package once so users + role grants exist immediately. See [scripts/oracle/ad-sync-install.sql](scripts/oracle/ad-sync-install.sql) for the full content and [docs/17](docs/17-external-users-and-ad-sync.md) for the architecture.
    - **Success:** the final state report at the end prints rows for `ALICE@MYLAB.LOCAL`, `BOB@MYLAB.LOCAL`, `CAROL@MYLAB.LOCAL` (each `EXTERNAL`) and matching `ORA_*_ROLE` grants.

22. **[ORA]** Check the sync log for clean execution:
    ```sql
    SQL> ALTER SESSION SET CONTAINER = orclpdb1;
    SQL> SELECT TO_CHAR(ts,'HH24:MI:SS.FF3'), lvl, msg FROM ad_sync.ad_sync_log ORDER BY ts;
    ```
    - **Success:** no `ERROR` rows. Lines like `START`, `INFO ldap_open OK`, `GRANT ORA_READERS_ROLE -> ALICE@MYLAB.LOCAL`, `END`.

---

## Phase 3 · Windows client setup (on `wks01`)

> Detailed narrative in [docs/13-domain-joined-workstation.md](docs/13-domain-joined-workstation.md) (domain-joined VM) or [docs/05](docs/05-windows-client-mit-krb.md) + [docs/06](docs/06-windows-lsa-and-ccache.md) (non-domain laptop). Vagrantfile at [lab/](lab/) provisions the whole thing automatically.

23. **[WKS]** Domain-joined to `MYLAB.LOCAL`. (If using a non-domain laptop, install MIT Kerberos for Windows + use a file ccache instead — see chapter 05.)

24. **[WKS]** Import the Root CA cert (`mylab-root-ca.cer`) into `Cert:\LocalMachine\Root`:
    ```powershell
    Import-Certificate -FilePath C:\path\to\mylab-root-ca.cer -CertStoreLocation Cert:\LocalMachine\Root
    ```

25. **[WKS]** Enable LSA TGT session-key visibility for user-mode JVMs (required for DBeaver to read the Windows LSA ticket cache):
    ```powershell
    reg add HKLM\SYSTEM\CurrentControlSet\Control\Lsa\Kerberos\Parameters /v allowtgtsessionkey /t REG_DWORD /d 1 /f
    ```
    **Reboot after setting.**

26. **[WKS]** Install DBeaver Community 25.x:
    ```powershell
    winget install dbeaver.dbeaver
    ```

27. **[WKS]** Drop the four Oracle JDBC jars into `C:\Program Files\dbeaver\drivers\oracle\` (download as the bundle `ojdbc8-full.tar.gz` from Oracle):
    - `ojdbc8.jar` (23.3.0.23.09)
    - `oraclepki.jar` (21.9.0.0)
    - `osdt_core.jar` (21.9.0.0)
    - `osdt_cert.jar` (21.9.0.0)

28. **[WKS]** Edit `C:\Program Files\dbeaver\dbeaver.ini` — paste the JVM args from [config/windows/dbeaver-jvm-args.example](config/windows/dbeaver-jvm-args.example) directly under the `-vmargs` line. **Include the full `--add-opens` set** (15 lines); without them Kerberos fails with `InaccessibleObjectException`. **Restart DBeaver after editing.**

29. **[WKS]** Create `C:\ProgramData\MIT\Kerberos5\krb5.ini` — content per [RECIPE.md §3e](RECIPE.md). **Critical line: `forwardable = false`** — this is the fix for the JDBC `EncryptionKey: Key bytes cannot be null` bug.

30. **[WKS]** In DBeaver, create a new Oracle connection (DBeaver UI: *Database → New Database Connection → Oracle*). On the Connection Settings → Main tab:
    - Host: `ora01.mylab.local`
    - Port: `1521`
    - Service Name: `orclpdb1`
    - Database type: `SID/SERVICE` → choose **Service Name**
    - Username and Password: **leave blank**

31. **[WKS]** On the connection's Driver properties tab, set these four properties:

    | Property | Value |
    |---|---|
    | `oracle.net.authentication_services` | `KERBEROS5` (**bare**, no parens) |
    | `oracle.net.kerberos5_mutual_authentication` | `false` |
    | `oracle.net.kerberos5_cc_name` | `C:/Users/<user>/krb5cc` (forward slashes) |
    | `oracle.net.kerberos5_conf` | `C:/ProgramData/MIT/Kerberos5/krb5.ini` (forward slashes) |

32. **[WKS]** Open the connection's `data-sources.json` (`%APPDATA%\DBeaverData\workspace6\General\.dbeaver\data-sources.json`) and confirm `"auth-model": "oracle_native"` — **not** `"oracle_os"`. Edit if needed and restart DBeaver.

---

## Phase 4 · End-to-end validation

> Run the queries below in DBeaver's SQL editor on `wks01`, signed in as `MYLAB\alice`.

33. **[WKS as alice]** Open DBeaver, double-click the `ORCLPDB1` connection. **No password prompt.**

34. **[WKS]** Run:
    ```sql
    SELECT USER FROM DUAL;
    ```
    - **Success:** returns `ALICE@MYLAB.LOCAL`.

35. **[WKS]** Run:
    ```sql
    SELECT SYS_CONTEXT('USERENV','AUTHENTICATION_METHOD'),
           SYS_CONTEXT('USERENV','SESSION_USER'),
           SYS_CONTEXT('USERENV','OS_USER')
    FROM DUAL;
    ```
    - **Success:** `KERBEROS | ALICE@MYLAB.LOCAL | alice@MYLAB.LOCAL`.

36. **[WKS]** Run:
    ```sql
    SELECT ROLE FROM SESSION_ROLES;
    ```
    - **Success:** includes `ORA_READERS_ROLE`. (`ORA_WRITERS_ROLE` if signed in as bob.)

37. **[WKS]** Run a query that exercises the role:
    ```sql
    SELECT COUNT(*) FROM ALL_TABLES;
    ```
    - **Success:** returns a number > 0 (proves `SELECT ANY TABLE` granted via `ORA_READERS_ROLE` works).

If all four checks pass — the build is complete and production-ready.

---

## Phase 5 · Day-2 operations (reference, run as needed)

38. **[AD]** Add a new person to the readers group:
    ```powershell
    Add-ADGroupMember -Identity oracle-readers -Members <samAccountName>
    ```
    Effect: within 10 minutes the scheduler creates `<UPN>@MYLAB.LOCAL` as `IDENTIFIED EXTERNALLY` in `orclpdb1` and grants `ORA_READERS_ROLE`. **Or**, the AFTER LOGON trigger does the same in ~5 ms on their next DBeaver connect.

39. **[AD]** Move someone between groups:
    ```powershell
    Remove-ADGroupMember -Identity oracle-readers -Members <samAccountName>
    Add-ADGroupMember    -Identity oracle-writers -Members <samAccountName>
    ```
    Next sync flips the role grants.

40. **[ORA]** Force a sync now (instead of waiting for the 10-min tick):
    ```sql
    SQL> ALTER SESSION SET CONTAINER = orclpdb1;
    SQL> BEGIN ad_sync.ad_sync.run; END;
    /
    ```

41. **[ORA]** Inspect what the last sync did:
    ```sql
    SQL> SELECT TO_CHAR(ts,'HH24:MI:SS.FF3'), lvl, msg
         FROM ad_sync.ad_sync_log ORDER BY ts;
    ```

42. **[AD + ORA]** Rotate the `svc-ora01` keytab — see [docs/10](docs/10-operations-rotation.md). One-line summary: re-run `ktpass` with a new password (resets AD + emits a new keytab), `scp` to `ora01`, replace the file, `lsnrctl reload`.

43. **[AD + ORA]** Rotate the `svc-ora-ldap` password:
    ```powershell
    # [AD]
    Set-ADAccountPassword -Identity svc-ora-ldap -Reset -NewPassword (Read-Host -AsSecureString)
    ```
    Then on `ora01`:
    ```bash
    $ORACLE_HOME/bin/mkstore -wrl /u01/app/oracle/cmu/wallet \
      -modifyEntry ORACLE.SECURITY.PASSWORD <new-password>
    $ORACLE_HOME/bin/lsnrctl reload
    ```
    Validate: re-run `ad_sync.ad_sync.run` and check the log for `ldap_open OK`.

---

## When things break

Anchored error reference: [troubleshooting.md](troubleshooting.md). Common starting points:

| Symptom | Section |
|---|---|
| Clock skew, `KRB_AP_ERR_SKEW` | [#clock-skew](troubleshooting.md#clock-skew) |
| `KDC_ERR_S_PRINCIPAL_UNKNOWN` (SPN missing/duplicated) | [#kdc-err-s-principal-unknown](troubleshooting.md#kdc-err-s-principal-unknown), [#duplicate-spn](troubleshooting.md#duplicate-spn) |
| `KRB_AP_ERR_MODIFIED` (keytab vs AD password mismatch) | [#krb-ap-err-modified](troubleshooting.md#krb-ap-err-modified) |
| `ORA-12631`, `ORA-12638`, `ORA-12641` | sections of [troubleshooting.md](troubleshooting.md) by error code |
| DBeaver: `EncryptionKey: Key bytes cannot be null` | [#jdbc-encryptionkey-null](troubleshooting.md#jdbc-encryptionkey-null) |
| `ORA-24247` from `ad_sync` | [#ora-24247](troubleshooting.md#ora-24247) |
| `ORA-28030` | [#ora-28030](troubleshooting.md#ora-28030) (and [docs/16](docs/16-cmu-19c-failure-mode.md) for background) |
