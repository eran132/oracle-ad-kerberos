# 15 · Questions and answers

A flat list of the questions that came up while building this lab, plus a few obvious follow-ups, with concise answers and pointers into the deeper chapters.

---

## Tickets and `kinit`

### Will I have to run `kinit` every time?

**It depends on which client you use.**

| Client | Need to `kinit`? |
|---|---|
| **`wks01` — domain-joined Windows VM** (chapter [13](13-domain-joined-workstation.md), built by [lab/](../lab/)) | **No.** When you log in interactively to Windows as `MYLAB\alice`, the OS obtains a TGT into the LSA cache automatically and the JVM reads it via SSPI/JGSS. You never run `kinit` at all. Just log in, open DBeaver, connect. |
| **A non-domain-joined Windows host** (your real laptop, e.g. — chapter [05](05-windows-client-mit-krb.md)) | **Yes, but rarely.** AD's default TGT lifetime is 10 hours, renewable for 7 days. So once per workday-ish: `kinit alice@MYLAB.LOCAL`, type password, work all day. `kinit -R` extends the existing TGT inside the renewable window without a password prompt. |

### How do I avoid even the daily `kinit` on a non-domain laptop?

Generate a keytab for the user (e.g. alice) and either:

1. Run `kinit -k -t alice.keytab alice@MYLAB.LOCAL` from a Task Scheduler trigger at logon. Zero password prompts.
2. Wrap DBeaver in a launcher script that does `kinit -k` first, then `dbeaver.exe`.

Cost: the keytab is the long-term key — anyone who can read the file *is* alice. Treat as a private key (NTFS ACL locked to your user, never in version control). Also `ktpass` rotates alice's AD password as a side effect.

### What's the difference between Windows `klist` and MIT `klist`?

They look at different caches.

| Tool | Reads from |
|---|---|
| `C:\Windows\System32\klist.exe` (Windows native) | LSA cache — what Windows logon creates |
| `C:\Program Files\MIT\Kerberos\bin\klist.exe` (MIT KfW) | File cache pointed to by `KRB5CCNAME` (e.g. `FILE:C:\Users\you\krb5cc`) |

On a domain-joined Windows machine you have both. They don't interfere — they just see different tickets. The JVM is the only piece that has to be told (via `KRB5CCNAME` env var or LSA + `allowtgtsessionkey` reg key) which one to look at.

### What's the `allowtgtsessionkey` registry key for?

By default Windows hides the TGT session key from user-mode processes. The JVM is user-mode, so it can't read the LSA-cached TGT. Setting `HKLM\SYSTEM\CurrentControlSet\Control\Lsa\Kerberos\Parameters\allowtgtsessionkey = 1` (and rebooting) lifts that veil so JGSS-via-SSPI can pull the TGT and forge a service ticket for Oracle. Required on `wks01` (the provisioner sets it). Not required on a non-domain laptop using a file ccache.

### My TGT expired in the middle of a DBeaver session. What happens?

DBeaver's existing connections keep working until they hit a server-side timeout — Oracle holds the session, not the Kerberos ticket. **New** connections fail with `ORA-12638` / `KrbException: No valid credentials provided`. Fix: `kinit -R` (or just re-`kinit alice@MYLAB.LOCAL`) and reconnect.

---

## Where do I run X?

### On which machine do I install DBeaver?

The machine you'll actually click around in. Two choices:

- **wks01** (chapter [13](13-domain-joined-workstation.md)) — recommended for the realistic flow with no `kinit` ceremony.
- **Your laptop** (chapter [07](07-dbeaver-oracle-driver.md)+[08](08-dbeaver-connection.md)) — works but you'll `kinit` once a day.

**Not** on `ad1` (it's a DC, no GUI tools belong there) and **not** on `ora01` (Linux, not Windows).

### On which machine do I run `kinit`?

The same one DBeaver runs on. The TGT and DBeaver's JVM have to live in the same OS account so the JVM can see the ticket.

### On which machine do I install MIT Kerberos for Windows?

Only on a **non-domain-joined** client. wks01 doesn't need it — Windows native Kerberos handles everything. Your laptop needs it because corporate Windows is in a different domain and so its native Kerberos can't talk to `MYLAB.LOCAL`.

### My laptop is corp-domain-joined. Can it still be the DBeaver client?

Yes — Windows runs both Kerberos stacks side by side without conflicts. Your corporate TGT lives in LSA; alice's TGT from `kinit` lives in a file ccache. They never see each other. See chapter [05](05-windows-client-mit-krb.md) and the `KRB5CCNAME` discussion in [06](06-windows-lsa-and-ccache.md).

The trade-off is the `kinit` cadence above and the corporate GPO risk: a future `gpupdate` could prune `mylab-root-ca` from `LocalMachine\Root` or revert your host's `KRB5CCNAME` env var. See "GPO survival" in chapter [05](05-windows-client-mit-krb.md).

---

## DBeaver specifics

### Why four Oracle jars, not just `ojdbc8.jar`?

`ojdbc8` is the wire-protocol driver; it doesn't ship the Kerberos5 handler. That lives in `oraclepki.jar`. `oraclepki` references ASN.1 / crypto classes in `osdt_core.jar` and X.509 classes in `osdt_cert.jar` at class init. Drop any one and you get `NoClassDefFoundError` at connect. Full per-jar justification in chapter [07 §5](07-dbeaver-oracle-driver.md) and the table in chapter [14](14-air-gapped.md).

### Why are `ojdbc8` (23.3.0.23.09) and `osdt_*` (21.9.0.0) on different version trains?

Oracle ships them from different product teams on independent cadences. The matched pair is whatever's in Oracle's `ojdbc8-full.tar.gz` bundle — currently ojdbc8 23.3 + osdt 21.9. **Don't try to force osdt to 23.x; it doesn't exist on Maven Central.**

### Can I use `ojdbc11` instead?

Yes — same Kerberos behavior. Swap each `ojdbc8.jar` reference for `ojdbc11.jar` from the same Maven group (`com.oracle.database.jdbc:ojdbc11`). DBeaver needs at least Java 11, which 26.x already bundles.

### Does DBeaver phone home on startup?

By default, yes — it checks `dbeaver.io` for updates. The offline provisioner ([02-install-dbeaver-offline.ps1](../lab/provision/02-install-dbeaver-offline.ps1)) writes a workspace preference that disables this. You can also do it manually: Window → Preferences → General → uncheck **Check for updates on startup**.

### My `dbeaver.ini` edits don't take effect.

Two common reasons:
1. **Wrong `dbeaver.ini`.** Each install has its own. winget per-user install lives at `C:\Users\<you>\AppData\Local\DBeaver\dbeaver.ini`; the portable install in wks01 is at `C:\Program Files\dbeaver\dbeaver.ini`. Edit the one next to the `dbeaver.exe` you're actually launching.
2. **DBeaver was still running.** Close *all* DBeaver windows (including the splash screen), then relaunch. JVM args are read once at startup.

### What about the DBeaver wiki page on Kerberos auth?

There's a wiki page at <https://github.com/dbeaver/dbeaver/wiki/Kerberos-Authentication> from April 2023. It's **partially stale and partially Community-incompatible**:

- The Kerberos UI panel ("Use kinit" checkbox etc.) it documents is only present in **DBeaver Lite / Enterprise / Ultimate**. Community edition (what this lab uses) has no such panel. The working recipe in [docs/08](08-dbeaver-connection.md) is the only path for Community.
- It warns: *"Oracle JDBC driver 21 has broken Kerberos authentication, at least for most of the old configurations. Use an older driver (12.x or 19.x)."* This was true historically but is **not** what we ship. We use `ojdbc8 23.3.0.23.09` and it works — **only because** we do the manual setup the wiki doesn't cover: `dbeaver.ini` JVM args (with the full `--add-opens` set), bare `KERBEROS5` in driver properties (not `(KERBEROS5)`), `oracle.net.kerberos5_mutual_authentication=false`, `auth-model: oracle_native` in `data-sources.json`, and `forwardable = false` in `krb5.ini`.

So: skim the wiki for context, but the authoritative recipe for Community on this lab is [docs/08-dbeaver-connection.md](08-dbeaver-connection.md) + [config/windows/dbeaver-jvm-args.example](../config/windows/dbeaver-jvm-args.example).

### Why does the lab not use Oracle Centrally Managed Users (CMU)?

Because Oracle 19c's CMU + Kerberos code path is broken in a way only Oracle Support can resolve — Oracle's NTZ (TLS) layer closes the TCP socket to AD's LDAPS port 7 ms after establishing it, without ever sending Client Hello. Same failure across every documented configuration. See [docs/16-cmu-19c-failure-mode.md](16-cmu-19c-failure-mode.md) for the full investigation and [docs/17-external-users-and-ad-sync.md](17-external-users-and-ad-sync.md) for what we ship instead. Same end-user behavior, no broken Oracle code path.

---

## Operations

### `ad1` keeps powering off. Why?

Most likely you're closing the VirtualBox console window. The default action on close is "Power Off the machine" which is a hard shutdown. To keep ad1 alive:

- **Minimize** the window (don't close), or
- **File → Detach GUI** — leaves the VM running in the background, or
- When the close dialog appears, choose **Save the machine state** (not "Power Off"). `VBoxManage startvm` will resume from saved state in seconds.

We also saw the `0xC0000005` headless-startup crash on this host. GUI mode works around it.

### How do I rotate alice/bob/carol's password?

On ad1 as Domain Admin:

```powershell
$pw = ConvertTo-SecureString '<new>' -AsPlainText -Force
Set-ADAccountPassword -Identity alice -Reset -NewPassword $pw
Set-ADUser -Identity alice -PasswordNeverExpires $true -ChangePasswordAtLogon $false
```

No keytab regeneration needed for alice — alice is a *user* principal, no keytab. **Only `svc-ora01` has a keytab**, and rotating its password requires re-running `ktpass-keytabs.ps1` and redeploying `/etc/oracle/keytabs/ora01.keytab` on ora01. See [troubleshooting.md#krb-ap-err-modified](../troubleshooting.md#krb-ap-err-modified).

### How do I switch between alice / bob / carol?

In `wks01`: sign out of Windows, sign back in as the other user. New logon = new LSA TGT = DBeaver picks up the new identity automatically. Run `SELECT USER FROM DUAL` after reconnecting to confirm.

On your laptop: `kdestroy; kinit bob@MYLAB.LOCAL` then reconnect in DBeaver. Same effect via file ccache.

### Why is the Oracle username `ALICE@MYLAB.LOCAL` (upper-case)?

Oracle stores externally-identified users *as quoted strings* and the realm part of a Kerberos principal is conventionally upper-case (`MYLAB.LOCAL`). The `oracle21c-kerberos.sh` script creates the user with `CREATE USER "ALICE@MYLAB.LOCAL" IDENTIFIED EXTERNALLY` — the upper-case is baked in. If the JVM ever presents `alice@mylab.local` (lower-case) the match fails and you get GSS errors. See [troubleshooting.md#gss-defective-token](../troubleshooting.md#gss-defective-token).

---

## Kerberos, SPN & AD service accounts

### Why two service accounts (`svc-ora01` and `svc-ora-ldap`)? Why not combine them?

`svc-ora01` is the Kerberos *service identity* (holds the SPN; its key is the keytab — authenticates the user). `svc-ora-ldap` is the *directory reader* (Oracle binds to AD as it to read `memberOf` — authorizes the user). They must stay separate primarily because `svc-ora01`'s password changes on *every* `ktpass` run while `svc-ora-ldap`'s must stay stable (the wallet holds a copy); merging them makes routine keytab rotation silently break authorization. Plus least-privilege/blast-radius. Full reasoning: [docs/20 §1](20-architecture-and-hardening.md), [docs/19 §A3](19-ad-admin-runbook.md).

### Does `ktpass -mapuser` point at a user account or the host/computer account?

A dedicated **user** service account (`svc-ora01`) — for an Oracle-keytab-on-Linux scenario, unambiguously. Computer-account passwords auto-rotate (~30 days) and would silently invalidate a static keytab. (`-mapuser` *can* target a machine account for native Windows services generally, but not for this case.) [docs/19 §A2](19-ad-admin-runbook.md).

### Why `-crypto AES256-SHA1` and not `-crypto All`?

`All` writes weak DES/RC4 keys into the keytab too — weak key material at rest, a re-opened RC4 downgrade path, and inconsistent account state. AES256-only is strong-or-fail. [docs/19 §A2 "Why not `-crypto All`?"](19-ad-admin-runbook.md).

### Why `-ptype KRB5_NT_PRINCIPAL`?

It means "use the principal name *literally*, no canonicalization" — required because Oracle/MIT/Java match the SPN byte-for-byte. The host-based types (`KRB5_NT_SRV_HST`) let the KDC rewrite the hostname, breaking the match. [docs/03 ktpass note](03-ad-and-spn-setup.md) · [docs/19 §A2](19-ad-admin-runbook.md).

### Why is the realm `MYLAB.LOCAL` upper-case but the host `ora01.mylab.local` lower-case?

Two different namespaces: the host is DNS (case-insensitive, lowercase convention); the realm is a Kerberos identifier (case-*sensitive*, and AD's realm literally *is* the uppercased DNS domain). Lowercasing the realm in `krb5.ini` → "Cannot find KDC for realm". [docs/03 "Naming & case conventions"](03-ad-and-spn-setup.md).

### Do we need Kerberos delegation?

No. There is no second hop performed *as the end user* (Oracle→AD binds as `svc-ora-ldap`'s own credential, not a forwarded user ticket). Never set "Trust this account for delegation" on the service accounts; `forwardable = false` in `krb5.ini` additionally makes delegation impossible. Avoiding it is a security strength. [docs/20 §7](20-architecture-and-hardening.md), [docs/19 §A1](19-ad-admin-runbook.md).

### Can I automate the `svc-ora-ldap` wallet-password rotation?

Yes, but weigh four gotchas (interactive `mkstore`, two-system non-atomicity — mitigated by the fail-open circuit breaker, `CannotChangePassword`, and a secret-zero/privilege trade-off). For a single low-privilege account, a quarterly manual runbook step is often the lower-risk choice; automate only for frequent policy rotation. Design + decision criteria: [docs/19 Part B3](19-ad-admin-runbook.md).

---

## Air-gapped / offline

### What gets downloaded during install? Can I see the inventory?

Yes — chapter [14](14-air-gapped.md) lists every URL, every size, every checksum. Chapter [12](12-install-record.md) records what was actually downloaded during the original build. The bundle layout for offline use is in [lab/bundle/README.md](../lab/bundle/README.md).

### Will the offline `vagrant up` actually work without internet?

Yes, empirically proven (2026-05-14). The Vagrantfile in `LAB_OFFLINE=1` mode:
1. Refuses to start if `lab/bundle/` is incomplete (with a clear list of missing files).
2. Uploads every binary from the bundle into the guest via WinRM.
3. Runs the offline provisioner ([02-install-dbeaver-offline.ps1](../lab/provision/02-install-dbeaver-offline.ps1)) which verifies SHA-256 checksums, extracts/installs everything from local files, wires the JVM args, and disables runtime update checks.

No outbound HTTPS during installation.

### What about the Vagrant box itself? Can I transfer that too?

Yes. `vagrant box add` accepts a pre-downloaded `.box` file (just a tarball). On the build PC: `vagrant box add gusztavvargadr/windows-11 --provider virtualbox` writes to `%USERPROFILE%\.vagrant.d\boxes\`. Copy that subtree to the air-gapped PC's `%USERPROFILE%\.vagrant.d\boxes\` and Vagrant finds it locally. Same for `gusztavvargadr/windows-server-2022-standard`, `generic/rocky9`, etc.

---

## When something looks wrong

### `Connection test` is red. Where do I start?

The connection test dialog usually surfaces the underlying error in its `Details>>` panel. Match it against [troubleshooting.md](../troubleshooting.md) — every common error mode is anchored there (`#clock-skew`, `#kdc-err-s-principal-unknown`, `#enctype-mismatch`, `#ora-12638`, `#gss-defective-token`, `#jdbc-noclassdef-o5login`, `#ldaps-no-cert`, `#ldaps-chain-untrusted`, …).

### How do I see what the JVM is doing?

In `dbeaver.ini`, flip these from `false` to `true`:

```
-Dsun.security.krb5.debug=true
-Dsun.security.jgss.debug=true
```

Restart DBeaver **from a terminal** (not by clicking the icon) so the JVM's stderr is visible:

```powershell
PS> & 'C:\Program Files\dbeaver\dbeaver.exe'
```

You'll see the full AS-REQ / TGS-REQ / AP-REQ trace. Flip back to `false` once it works again — the debug output is *noisy*.

### One last sanity script.

```powershell
PS> cd C:\Users\<you>\Documents\oracle_Ad_kerberos
PS> .\scripts\windows\Invoke-DBeaverPrecheck.ps1 -DoKinit
```

All-green means: DNS, ports, clock skew, krb5.ini, LDAPS handshake + chain validation, SPN registration, AES enctype, listener reachable, TGT acquired, service ticket acquired. If this passes and DBeaver still won't connect, the problem is between DBeaver's JVM and the ticket cache — see chapters [06](06-windows-lsa-and-ccache.md) and [08](08-dbeaver-connection.md).
