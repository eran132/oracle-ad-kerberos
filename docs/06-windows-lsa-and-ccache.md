# 06 · LSA tweak and credential cache routing

DBeaver runs on the JVM, and the JVM's GSSAPI implementation reads its TGT from a Kerberos credential cache. Where that cache lives — and whether the JVM is allowed to read it — is the single most common cause of "the JDBC driver can't find my Kerberos ticket" on Windows.

This chapter pins both sides down so DBeaver and the command-line MIT tools share **the same** credential cache.

---

## 1. Two cache options on Windows

| Mode | Cache location | What sees it | When to use |
|---|---|---|---|
| **LSA cache** (Windows native) | Kernel-managed, owned by `lsass.exe` | Native `klist.exe`, SSPI apps, JDBC *only if* `allowtgtsessionkey=1` | Domain-joined hosts where users log in interactively to AD. |
| **File ccache** (MIT KfW style) | Plain file at `%KRB5CCNAME%` | MIT `kinit/klist/kvno`, JDBC if pointed at the file | **This lab.** Host is not domain-joined; tickets come from `kinit`, not from interactive login. |

This lab uses **file ccache**. You can ignore the LSA registry tweak entirely if you stick to file mode. The tweak is documented anyway because every "JDBC + Kerberos on Windows" tutorial mentions it, and you'll want to know why this lab does *not* depend on it.

## 2. File ccache configuration (recommended)

### 2a. Choose a path

Anywhere your user can write. The convention used by this lab:

```powershell
PS> $env:KRB5CCNAME = "FILE:C:\Users\<you>\krb5cc"
```

The `FILE:` prefix is required when the value is read by Java/JGSS. MIT `kinit` accepts both `FILE:C:\path` and bare `C:\path`, but the JVM is strict.

### 2b. Make it persistent

For the Windows user, so every shell + DBeaver inherits it:

```powershell
PS> [Environment]::SetEnvironmentVariable("KRB5CCNAME", "FILE:C:\Users\<you>\krb5cc", "User")
```

Then **fully close DBeaver and any PowerShell windows** — Windows only re-reads env vars on process start. Reopen a new PowerShell to verify:

```powershell
PS> $env:KRB5CCNAME
FILE:C:\Users\<you>\krb5cc
```

### 2c. First kinit writes the file

```powershell
PS> kinit alice@MYLAB.LOCAL
Password for alice@MYLAB.LOCAL: ********
PS> Test-Path C:\Users\<you>\krb5cc
True
PS> klist
Ticket cache: FILE:C:\Users\<you>\krb5cc
Default principal: alice@MYLAB.LOCAL
  ...
```

The `Ticket cache:` line on `klist` should match `$env:KRB5CCNAME`. If it says `API:Initial default ccache`, MIT couldn't open the file path you set — usually a permissions or path-format issue. Re-check the `FILE:` prefix.

### 2d. DBeaver inheriting `KRB5CCNAME`

Because you set the variable at User scope, **any** new DBeaver process launched from the Start Menu or Desktop will see it. You can confirm from inside DBeaver after a connection attempt by reading `Help → About → Configuration` (look for `KRB5CCNAME` in the system properties dump), or by running `Process Explorer` and inspecting the `dbeaver.exe` environment.

The JVM-side property `-Djava.security.krb5.conf` points the JVM at `krb5.ini`. The ccache is **not** named in JVM args — JGSS uses `KRB5CCNAME` from the environment. See [config/windows/dbeaver-jvm-args.example](../config/windows/dbeaver-jvm-args.example) and chapter [08](08-dbeaver-connection.md).

## 3. LSA tweak — only if you choose LSA cache mode

If you decide to use the Windows native cache instead (host is domain-joined, users get a TGT from interactive logon), the JVM needs explicit permission to read the session key from the LSA. By default Windows hides this from user-mode apps for security reasons.

The flag:

```
HKEY_LOCAL_MACHINE\SYSTEM\CurrentControlSet\Control\Lsa\Kerberos\Parameters
  allowtgtsessionkey  (REG_DWORD) = 1
```

Apply via the provided reg file:

```powershell
PS> reg import .\config\windows\allowtgtsessionkey.reg
PS> Restart-Computer    # required — LSA reads this at boot
```

Then a JVM running as the logged-in domain user can call `useSubjectCredsOnly=false`, GSSAPI will pick up the LSA TGT, and DBeaver works without `kinit`.

**Why this lab does not do this:**
- The Windows host is not domain-joined to `mylab.local` (AD lives only in VirtualBox).
- The user we authenticate as is `alice` — not the Windows console user — so there's no LSA TGT for `alice` to read anyway.
- File ccache mode is simpler to reason about and to debug; you can `klist` and see exactly what DBeaver will see.

The .reg snippet is included so you can repurpose this repo for a domain-joined host without rewriting the runbook.

## 4. JVM properties that interact with the cache

These get set in `dbeaver.ini` (see [08](08-dbeaver-connection.md) and [config/windows/dbeaver-jvm-args.example](../config/windows/dbeaver-jvm-args.example)):

| Property | This lab's value | What it does |
|---|---|---|
| `-Djava.security.krb5.conf` | `C:\ProgramData\MIT\Kerberos5\krb5.ini` | Realm config the JVM uses. **Must match** what MIT `kinit` used or the principal canonicalization differs. |
| `-Djavax.security.auth.useSubjectCredsOnly` | `false` | Lets JGSS pull credentials from the ccache instead of requiring a `Subject` set up by JAAS. Standard for DBeaver-style apps. |
| `-Dsun.security.krb5.debug` | `true` *(temporarily)* | Dumps the entire AS/TGS exchange to DBeaver's console. Indispensable when troubleshooting; **noisy**, turn off once it works. |
| `-Dsun.security.jgss.debug` | `true` *(temporarily)* | GSS-layer debug (token negotiation, mech selection). Pair with `krb5.debug`. |

`KRB5CCNAME` is read from the environment — not a JVM property — but make sure to verify it inside DBeaver because env-var inheritance is the surprise that breaks people every time. See [troubleshooting.md#gss-defective-token](../troubleshooting.md#gss-defective-token).

## 5. Quick sanity check before moving on

```powershell
PS> $env:KRB5CCNAME             # FILE:C:\Users\<you>\krb5cc
PS> kinit alice@MYLAB.LOCAL     # prompt, then silent
PS> klist                       # Ticket cache line matches above
PS> kvno oracle/ora01.mylab.local@MYLAB.LOCAL   # kvno = N
PS> klist                       # now shows both krbtgt and oracle/... entries
```

If all four lines pass, the cache is wired correctly and you are ready to install the Oracle JDBC driver in DBeaver: [07 · DBeaver Oracle driver](07-dbeaver-oracle-driver.md).
