-- ============================================================================
-- ad-sync-install.sql
--
-- Idempotent installer for the AD-driven user-and-role sync that this lab uses
-- instead of Oracle Centrally Managed Users. See:
--   docs/16-cmu-19c-failure-mode.md      why CMU is not used on 19c
--   docs/17-external-users-and-ad-sync.md what this script installs and why
--
-- Run as SYSDBA from a SQL*Plus / sqlcl session pointed at the CDB (any PDB
-- context inside; this script will ALTER SESSION SET CONTAINER itself).
-- Prerequisites already in place from the regular lab build:
--   - Oracle wallet at /u01/app/oracle/cmu/wallet (auto-login) containing:
--       * trusted_cert mylab-root-ca (the AD CS Enterprise Root CA)
--       * mkstore entries ORACLE.SECURITY.USERNAME / DN / PASSWORD for
--         the AD service account 'svc-ora-ldap'.
--     See scripts/linux/build-wallet.sh in the sibling tableau_ad_oracle repo.
--   - sqlnet.ora has WALLET_LOCATION = (... DIRECTORY = /u01/app/oracle/cmu/wallet )
--   - ad1.mylab.local resolves and is reachable on 636/tcp from ora01.
--   - AD groups oracle-readers and oracle-writers exist under
--     OU=Groups,DC=mylab,DC=local with the expected members.
--
-- Lab-specific values to search-replace if reusing this script elsewhere:
--   ad1.mylab.local                                    (LDAPS server)
--   DC=mylab,DC=local                                  (LDAP base DN)
--   svc-ora-ldap@MYLAB.LOCAL                           (LDAP bind UPN)
--   CN=oracle-readers,OU=Groups,DC=mylab,DC=local      (AD reader group DN)
--   CN=oracle-writers,OU=Groups,DC=mylab,DC=local      (AD writer group DN)
--
-- The svc-ora-ldap password is NOT in this file. It is provided at install
-- time via the SQL*Plus substitution variable &bind_pwd. Two install patterns:
--
--   (a) interactive: SQL*Plus will prompt for it (HIDE means no echo).
--   (b) wrapper:     scripts/oracle/run-ad-sync-install.sh sources .env and
--                    pre-defines bind_pwd before invoking sqlplus.
--
-- After install, the password lives inside DBA_SOURCE for the package body
-- (Oracle has no plaintext-credential primitive callable from PL/SQL DBMS_LDAP).
-- Restrict DBA_SOURCE access accordingly; consider DBMS_CREDENTIAL for prod.
-- ============================================================================

SET ECHO ON FEEDBACK ON LINES 200 VERIFY OFF

ACCEPT bind_pwd CHAR PROMPT 'svc-ora-ldap AD password (HIDDEN): ' HIDE

ALTER SESSION SET CONTAINER = orclpdb1;

-- ---------------------------------------------------------------------------
-- 1) Roles
-- ---------------------------------------------------------------------------
DECLARE
  PROCEDURE drop_role(r VARCHAR2) IS
  BEGIN
    EXECUTE IMMEDIATE 'DROP ROLE ' || r;
  EXCEPTION
    WHEN OTHERS THEN
      IF SQLCODE != -1919 THEN RAISE; END IF;  -- 1919 = role does not exist
  END;
BEGIN
  drop_role('ora_readers_role');
  drop_role('ora_writers_role');
END;
/

CREATE ROLE ora_readers_role;
CREATE ROLE ora_writers_role;

GRANT CREATE SESSION   TO ora_readers_role;
GRANT SELECT ANY TABLE TO ora_readers_role;

GRANT CREATE SESSION   TO ora_writers_role;
GRANT SELECT ANY TABLE TO ora_writers_role;
GRANT INSERT ANY TABLE TO ora_writers_role;
GRANT UPDATE ANY TABLE TO ora_writers_role;
GRANT DELETE ANY TABLE TO ora_writers_role;

-- ---------------------------------------------------------------------------
-- 2) Sync-owner schema (no login)
-- ---------------------------------------------------------------------------
DECLARE
BEGIN
  EXECUTE IMMEDIATE 'DROP USER ad_sync CASCADE';
EXCEPTION
  WHEN OTHERS THEN
    IF SQLCODE != -1918 THEN RAISE; END IF;  -- 1918 = user does not exist
END;
/

CREATE USER ad_sync NO AUTHENTICATION;

GRANT CREATE SESSION              TO ad_sync;
GRANT CREATE PROCEDURE            TO ad_sync;
GRANT CREATE TABLE                TO ad_sync;
GRANT UNLIMITED TABLESPACE        TO ad_sync;
GRANT EXECUTE ON DBMS_LDAP        TO ad_sync;
GRANT EXECUTE ON DBMS_OUTPUT      TO ad_sync;
GRANT SELECT  ON DBA_USERS        TO ad_sync;
GRANT SELECT  ON DBA_ROLE_PRIVS   TO ad_sync;
GRANT CREATE USER                 TO ad_sync;
GRANT ALTER USER                  TO ad_sync;
GRANT DROP USER                   TO ad_sync;
GRANT GRANT ANY ROLE              TO ad_sync;
GRANT GRANT ANY PRIVILEGE         TO ad_sync;

-- ---------------------------------------------------------------------------
-- 3) Network ACL: allow DBMS_LDAP from AD_SYNC to ad1.mylab.local
--    Without this the package fails with ORA-24247.
-- ---------------------------------------------------------------------------
BEGIN
  DBMS_NETWORK_ACL_ADMIN.append_host_ace(
    host => 'ad1.mylab.local',
    ace  => xs$ace_type(
              privilege_list => xs$name_list('connect','resolve'),
              principal_name => 'AD_SYNC',
              principal_type => xs_acl.ptype_db));
END;
/
COMMIT;

-- ---------------------------------------------------------------------------
-- 4) Log table (autonomous-tx writes from inside the package)
-- ---------------------------------------------------------------------------
CREATE TABLE ad_sync.ad_sync_log (
  ts        TIMESTAMP    DEFAULT SYSTIMESTAMP,
  lvl       VARCHAR2(10),   -- INFO / CREATE / GRANT / REVOKE / ERROR / START / END / PHASE / BREAKER
  msg       VARCHAR2(4000)
);

-- Circuit-breaker state (single row). After N consecutive LDAP failures the
-- breaker "opens" for a cooldown window: ldap_open() then fails fast WITHOUT
-- touching the network, so a DC outage cannot add latency to every login
-- (the AFTER LOGON trigger path in particular). It still fails OPEN for the
-- user (login succeeds, roles stay as last good) -- see docs/20 section 2.
CREATE TABLE ad_sync.ad_sync_breaker (
  id              NUMBER       DEFAULT 1 PRIMARY KEY,
  consec_failures NUMBER       DEFAULT 0 NOT NULL,
  open_until      TIMESTAMP
);
INSERT INTO ad_sync.ad_sync_breaker(id, consec_failures, open_until)
VALUES (1, 0, NULL);
COMMIT;

-- ---------------------------------------------------------------------------
-- 5) Package: ad_sync.ad_sync
-- ---------------------------------------------------------------------------
CREATE OR REPLACE PACKAGE ad_sync.ad_sync AS
  PROCEDURE run;
  PROCEDURE refresh_user_roles(p_principal IN VARCHAR2);
END ad_sync;
/

CREATE OR REPLACE PACKAGE BODY ad_sync.ad_sync AS

  c_ldap_host CONSTANT VARCHAR2(64)  := 'ad1.mylab.local';
  c_ldap_port CONSTANT PLS_INTEGER   := 636;
  c_base_dn   CONSTANT VARCHAR2(128) := 'DC=mylab,DC=local';
  c_bind_dn   CONSTANT VARCHAR2(128) := 'svc-ora-ldap@MYLAB.LOCAL';
  c_bind_pwd  CONSTANT VARCHAR2(64)  := '&bind_pwd';
  c_wallet    CONSTANT VARCHAR2(128) := 'file:/u01/app/oracle/cmu/wallet';

  -- Circuit-breaker tunables (must be declared before any subprogram body).
  c_breaker_threshold CONSTANT PLS_INTEGER := 3;    -- trip after N consecutive failures
  c_breaker_cooldown  CONSTANT PLS_INTEGER := 300;  -- seconds the breaker stays open

  TYPE t_group_map IS RECORD (group_dn VARCHAR2(256), role_nm VARCHAR2(30));
  TYPE t_group_maps IS TABLE OF t_group_map;

  FUNCTION group_map RETURN t_group_maps IS
    v t_group_maps := t_group_maps();
    PROCEDURE add(dn VARCHAR2, rn VARCHAR2) IS BEGIN v.EXTEND; v(v.LAST).group_dn := dn; v(v.LAST).role_nm := rn; END;
  BEGIN
    -- Add new (group, role) pairs here.
    add('CN=oracle-readers,OU=Groups,DC=mylab,DC=local', 'ORA_READERS_ROLE');
    add('CN=oracle-writers,OU=Groups,DC=mylab,DC=local', 'ORA_WRITERS_ROLE');
    RETURN v;
  END;

  PROCEDURE log(p_level VARCHAR2, p_msg VARCHAR2) IS
    PRAGMA AUTONOMOUS_TRANSACTION;
  BEGIN
    INSERT INTO ad_sync.ad_sync_log(lvl, msg) VALUES (p_level, SUBSTR(p_msg, 1, 4000));
    COMMIT;
  END;

  FUNCTION breaker_is_open RETURN BOOLEAN IS
    v TIMESTAMP;
  BEGIN
    SELECT open_until INTO v FROM ad_sync.ad_sync_breaker WHERE id = 1;
    RETURN v IS NOT NULL AND v > SYSTIMESTAMP;
  END;

  PROCEDURE breaker_success IS
    PRAGMA AUTONOMOUS_TRANSACTION;
  BEGIN
    UPDATE ad_sync.ad_sync_breaker
       SET consec_failures = 0, open_until = NULL
     WHERE id = 1 AND (consec_failures <> 0 OR open_until IS NOT NULL);
    COMMIT;
  END;

  PROCEDURE breaker_failure IS
    PRAGMA AUTONOMOUS_TRANSACTION;
    n NUMBER;
  BEGIN
    UPDATE ad_sync.ad_sync_breaker
       SET consec_failures = consec_failures + 1,
           open_until = CASE
             WHEN consec_failures + 1 >= c_breaker_threshold
               THEN SYSTIMESTAMP + NUMTODSINTERVAL(c_breaker_cooldown, 'SECOND')
             ELSE open_until END
     WHERE id = 1
    RETURNING consec_failures INTO n;
    COMMIT;
    IF n >= c_breaker_threshold THEN
      log('BREAKER', 'opened after ' || n || ' consecutive failures; cooldown '
                     || c_breaker_cooldown || 's');
    END IF;
  END;

  FUNCTION ldap_open RETURN DBMS_LDAP.session IS
    s DBMS_LDAP.session;
    r PLS_INTEGER;
  BEGIN
    -- Fast-fail without touching the network if the breaker is open.
    IF breaker_is_open THEN
      RAISE_APPLICATION_ERROR(-20901,
        'ad_sync circuit breaker open (recent consecutive LDAP failures) - skipping');
    END IF;
    DBMS_LDAP.use_exception := TRUE;
    s := DBMS_LDAP.init(c_ldap_host, c_ldap_port);
    r := DBMS_LDAP.open_ssl(s, c_wallet, NULL, 2);
    r := DBMS_LDAP.simple_bind_s(s, c_bind_dn, c_bind_pwd);
    breaker_success;             -- reset failure count on a clean bind
    RETURN s;
  END;

  FUNCTION members_of_group(s DBMS_LDAP.session, group_dn VARCHAR2) RETURN SYS.ODCIVARCHAR2LIST IS
    msg   DBMS_LDAP.message;
    ent   DBMS_LDAP.message;
    vals  DBMS_LDAP.string_collection;
    attrs DBMS_LDAP.string_collection;
    r     PLS_INTEGER;
    out   SYS.ODCIVARCHAR2LIST := SYS.ODCIVARCHAR2LIST();
    i     PLS_INTEGER;
  BEGIN
    attrs(1) := 'userPrincipalName';
    r := DBMS_LDAP.search_s(
           s, c_base_dn, DBMS_LDAP.SCOPE_SUBTREE,
           '(&(objectClass=user)(memberOf=' || group_dn || '))',
           attrs, 0, msg);
    ent := DBMS_LDAP.first_entry(s, msg);
    WHILE ent IS NOT NULL LOOP
      vals := DBMS_LDAP.get_values(s, ent, 'userPrincipalName');
      i := vals.FIRST;
      WHILE i IS NOT NULL LOOP
        out.EXTEND; out(out.LAST) := UPPER(vals(i));
        i := vals.NEXT(i);
      END LOOP;
      ent := DBMS_LDAP.next_entry(s, ent);
    END LOOP;
    r := DBMS_LDAP.msgfree(msg);
    RETURN out;
  END;

  FUNCTION groups_of_user(s DBMS_LDAP.session, p_upn VARCHAR2) RETURN SYS.ODCIVARCHAR2LIST IS
    msg DBMS_LDAP.message; ent DBMS_LDAP.message;
    vals DBMS_LDAP.string_collection; attrs DBMS_LDAP.string_collection;
    r PLS_INTEGER;
    out SYS.ODCIVARCHAR2LIST := SYS.ODCIVARCHAR2LIST();
    i PLS_INTEGER;
  BEGIN
    attrs(1) := 'memberOf';
    r := DBMS_LDAP.search_s(s, c_base_dn, DBMS_LDAP.SCOPE_SUBTREE,
           '(userPrincipalName=' || LOWER(p_upn) || ')', attrs, 0, msg);
    ent := DBMS_LDAP.first_entry(s, msg);
    IF ent IS NOT NULL THEN
      vals := DBMS_LDAP.get_values(s, ent, 'memberOf');
      i := vals.FIRST;
      WHILE i IS NOT NULL LOOP
        out.EXTEND; out(out.LAST) := vals(i);
        i := vals.NEXT(i);
      END LOOP;
    END IF;
    r := DBMS_LDAP.msgfree(msg);
    RETURN out;
  END;

  PROCEDURE ensure_user(p_upn VARCHAR2) IS
    n PLS_INTEGER;
  BEGIN
    SELECT COUNT(*) INTO n FROM DBA_USERS WHERE USERNAME = p_upn;
    IF n = 0 THEN
      BEGIN
        EXECUTE IMMEDIATE 'CREATE USER "' || p_upn || '" IDENTIFIED EXTERNALLY';
        log('CREATE', 'user ' || p_upn);
      EXCEPTION WHEN OTHERS THEN
        -- Concurrent first-logins of the same new principal can race here
        -- (two AFTER LOGON triggers both see n=0). ORA-01920 = user/role name
        -- conflict, ORA-00955 = name already used. Both mean "someone else
        -- just created it" - benign, swallow. Anything else re-raises.
        IF SQLCODE IN (-1920, -955) THEN
          log('INFO', 'user ' || p_upn || ' created concurrently - ok');
        ELSE
          RAISE;
        END IF;
      END;
    ELSE
      BEGIN
        EXECUTE IMMEDIATE 'ALTER USER "' || p_upn || '" ACCOUNT UNLOCK';
      EXCEPTION WHEN OTHERS THEN NULL; END;
    END IF;
  END;

  PROCEDURE grant_role(p_upn VARCHAR2, p_role VARCHAR2) IS
    n PLS_INTEGER;
  BEGIN
    SELECT COUNT(*) INTO n FROM DBA_ROLE_PRIVS WHERE GRANTEE = p_upn AND GRANTED_ROLE = p_role;
    IF n = 0 THEN
      EXECUTE IMMEDIATE 'GRANT ' || p_role || ' TO "' || p_upn || '"';
      log('GRANT', p_role || ' -> ' || p_upn);
    END IF;
  END;

  PROCEDURE revoke_role(p_upn VARCHAR2, p_role VARCHAR2) IS
    n PLS_INTEGER;
  BEGIN
    SELECT COUNT(*) INTO n FROM DBA_ROLE_PRIVS WHERE GRANTEE = p_upn AND GRANTED_ROLE = p_role;
    IF n > 0 THEN
      EXECUTE IMMEDIATE 'REVOKE ' || p_role || ' FROM "' || p_upn || '"';
      log('REVOKE', p_role || ' <- ' || p_upn);
    END IF;
  END;

  PROCEDURE run IS
    s DBMS_LDAP.session;
    maps t_group_maps := group_map();
    members SYS.ODCIVARCHAR2LIST;
    all_role_users SYS.ODCIVARCHAR2LIST;
    r_dummy PLS_INTEGER;
  BEGIN
    log('START', 'ad_sync.run');
    s := ldap_open;
    FOR g IN 1 .. maps.COUNT LOOP
      log('PHASE', 'GRANT for ' || maps(g).group_dn);
      members := members_of_group(s, maps(g).group_dn);
      FOR i IN 1 .. members.COUNT LOOP
        ensure_user(members(i));
        grant_role(members(i), maps(g).role_nm);
      END LOOP;
    END LOOP;
    FOR g IN 1 .. maps.COUNT LOOP
      log('PHASE', 'REVOKE for ' || maps(g).group_dn);
      members := members_of_group(s, maps(g).group_dn);
      SELECT GRANTEE BULK COLLECT INTO all_role_users
      FROM DBA_ROLE_PRIVS
      WHERE GRANTED_ROLE = maps(g).role_nm
        AND GRANTEE LIKE '%@MYLAB.LOCAL';
      FOR k IN 1 .. all_role_users.COUNT LOOP
        DECLARE in_grp BOOLEAN := FALSE;
        BEGIN
          FOR m IN 1 .. members.COUNT LOOP
            IF members(m) = all_role_users(k) THEN in_grp := TRUE; EXIT; END IF;
          END LOOP;
          IF NOT in_grp THEN revoke_role(all_role_users(k), maps(g).role_nm); END IF;
        END;
      END LOOP;
    END LOOP;
    r_dummy := DBMS_LDAP.unbind_s(s);
    log('END', 'ad_sync.run');
  EXCEPTION WHEN OTHERS THEN
    -- Don't double-count when the breaker itself short-circuited us.
    IF SQLCODE != -20901 THEN breaker_failure; END IF;
    log('ERROR', 'code=' || SQLCODE || ' msg=' || SQLERRM);
    log('ERROR', 'backtrace=' || DBMS_UTILITY.FORMAT_ERROR_BACKTRACE);
    BEGIN r_dummy := DBMS_LDAP.unbind_s(s); EXCEPTION WHEN OTHERS THEN NULL; END;
    RAISE;
  END;

  PROCEDURE refresh_user_roles(p_principal IN VARCHAR2) IS
    s DBMS_LDAP.session;
    user_dns SYS.ODCIVARCHAR2LIST;
    maps t_group_maps := group_map();
    r_dummy PLS_INTEGER;
  BEGIN
    s := ldap_open;
    user_dns := groups_of_user(s, p_principal);
    FOR g IN 1 .. maps.COUNT LOOP
      DECLARE in_grp BOOLEAN := FALSE;
      BEGIN
        FOR i IN 1 .. user_dns.COUNT LOOP
          IF UPPER(user_dns(i)) = UPPER(maps(g).group_dn) THEN in_grp := TRUE; EXIT; END IF;
        END LOOP;
        IF in_grp THEN
          ensure_user(p_principal);
          grant_role(p_principal, maps(g).role_nm);
        ELSE
          revoke_role(p_principal, maps(g).role_nm);
        END IF;
      END;
    END LOOP;
    r_dummy := DBMS_LDAP.unbind_s(s);
  EXCEPTION WHEN OTHERS THEN
    -- Fails OPEN by design (login proceeds; roles stay as last good). The
    -- breaker bounds repeated exposure so a DC outage can't slow every login.
    IF SQLCODE != -20901 THEN breaker_failure; END IF;
    log('ERROR', 'refresh(' || p_principal || ') code=' || SQLCODE || ' msg=' || SQLERRM);
    BEGIN r_dummy := DBMS_LDAP.unbind_s(s); EXCEPTION WHEN OTHERS THEN NULL; END;
  END;
END ad_sync;
/
SHOW ERRORS

GRANT EXECUTE ON ad_sync.ad_sync TO PUBLIC;

-- ---------------------------------------------------------------------------
-- 6) Run once now so role grants exist before the first login.
-- ---------------------------------------------------------------------------
BEGIN ad_sync.ad_sync.run; END;
/

-- ---------------------------------------------------------------------------
-- 7) Scheduler job (every 10 minutes, drift-correction)
-- ---------------------------------------------------------------------------
BEGIN
  BEGIN DBMS_SCHEDULER.drop_job('AD_SYNC.AD_SYNC_JOB', force=>TRUE); EXCEPTION WHEN OTHERS THEN NULL; END;
  DBMS_SCHEDULER.create_job(
    job_name        => 'AD_SYNC.AD_SYNC_JOB',
    job_type        => 'PLSQL_BLOCK',
    job_action      => 'BEGIN ad_sync.ad_sync.run; END;',
    start_date      => SYSTIMESTAMP,
    repeat_interval => 'FREQ=MINUTELY; INTERVAL=10',
    enabled         => TRUE,
    auto_drop       => FALSE,
    comments        => 'See docs/17-external-users-and-ad-sync.md');
END;
/

-- ---------------------------------------------------------------------------
-- 8) AFTER LOGON trigger (per-user JIT)
--    Must be SYS-owned because AFTER LOGON ON DATABASE only fires from SYS.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE TRIGGER sys.ad_sync_on_logon
AFTER LOGON ON DATABASE
DECLARE
  v_user VARCHAR2(256) := SYS_CONTEXT('USERENV','SESSION_USER');
BEGIN
  IF v_user LIKE '%@MYLAB.LOCAL' THEN
    BEGIN
      ad_sync.ad_sync.refresh_user_roles(v_user);
    EXCEPTION WHEN OTHERS THEN NULL;   -- never block login on sync failure
    END;
  END IF;
END;
/

-- ---------------------------------------------------------------------------
-- 9) Final state report
-- ---------------------------------------------------------------------------
COL USERNAME            FORMAT A28
COL AUTHENTICATION_TYPE FORMAT A12
SELECT USERNAME, AUTHENTICATION_TYPE
FROM   DBA_USERS WHERE USERNAME LIKE '%@MYLAB.LOCAL'
ORDER BY USERNAME;

COL GRANTEE      FORMAT A28
COL GRANTED_ROLE FORMAT A20
SELECT GRANTEE, GRANTED_ROLE
FROM   DBA_ROLE_PRIVS
WHERE  GRANTED_ROLE LIKE 'ORA_%_ROLE'
   AND GRANTEE LIKE '%@MYLAB.LOCAL'
ORDER BY GRANTEE;

COL JOB_NAME FORMAT A20
COL STATE    FORMAT A12
COL NEXT_RUN FORMAT A20
SELECT JOB_NAME, STATE,
       TO_CHAR(NEXT_RUN_DATE,'YYYY-MM-DD HH24:MI:SS') AS NEXT_RUN
FROM   ALL_SCHEDULER_JOBS
WHERE  OWNER='AD_SYNC';

UNDEFINE bind_pwd

PROMPT === install complete ===
