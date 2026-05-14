# 13 · Domain-joined workstation — the no-kinit path

Chapters 05–09 describe running DBeaver on a non-domain-joined Windows host (typically your laptop, which is joined to your *corporate* AD, not `mylab.local`). That setup works, but every TGT expiry forces you to type alice's password again.

If you instead use a Windows VM that is **joined to `mylab.local` itself**, Windows obtains the TGT automatically at interactive logon. The JVM reads it from the LSA cache via SSPI/JGSS. **No `kinit` ever.**

This chapter documents that path. The Vagrant infrastructure that builds the VM lives at [../lab/](../lab/).

---

## When to use this chapter

| Scenario | Use this chapter | Use chapter 05 |
|---|---|---|
| Your only Windows machine is your corporate laptop | ✗ | ✓ |
| You're OK with a separate VirtualBox VM for DBeaver work | ✓ | — |
| You want to mirror real analyst workstation experience (logon = ready to query) | ✓ | — |
| You can't install software (DBeaver, MIT KfW) on your laptop due to corporate policy | ✓ | — |
| You can't afford ~4 GB extra RAM for another VM | — | ✓ |

The two paths are not mutually exclusive — many labs run both. The verification scripts in `scripts/windows/` work the same on either.

## Comparison: what changes between non-joined and domain-joined

| Component | Non-joined laptop (ch. 05–09) | Domain-joined `wks01` (this chapter) |
|---|---|---|
| Where the TGT lives | File ccache (`KRB5CCNAME=FILE:...`) | LSA (Windows native), populated at logon |
| Who creates the TGT | `kinit` (interactive password) | Windows itself, at interactive logon |
| How JVM gets the TGT | Reads `KRB5CCNAME` file | Reads LSA via SSPI (needs `allowtgtsessionkey=1`) |
| MIT Kerberos for Windows | Required | Not required (but harmless if present) |
| `krb5.ini` | Required at `C:\ProgramData\MIT\Kerberos5\` | Not strictly required — JVM uses Windows native krb5 |
| Frequency of password entry | Once per TGT lifetime (default 10 h) | Once per Windows logon |
| `dbeaver.ini` JVM args | Includes `-Djava.security.krb5.conf=...` | Can omit `-Djava.security.krb5.conf` (JVM picks up Windows config) |
| `allowtgtsessionkey` registry tweak | Optional (only if you want LSA mode) | **Required** |

## Build the workstation VM

From this repo, in a PowerShell window:

```powershell
PS> cd lab
PS> $env:AD_ADMIN_USER = 'mylab\Administrator'
PS> $env:AD_ADMIN_PW   = '<your Administrator password>'
PS> vagrant up wks01
```

Details in [../lab/README.md](../lab/README.md).

The provisioner:

1. Pins DNS to `192.168.56.10`, syncs time to `ad1`
2. Imports `mylab-root-ca` to `Cert:\LocalMachine\Root`
3. Applies `allowtgtsessionkey=1` (the *only* version of [../config/windows/allowtgtsessionkey.reg](../config/windows/allowtgtsessionkey.reg) needed here)
4. Renames computer to `wks01` and joins `mylab.local`
5. Reboots
6. Downloads DBeaver portable zip + Oracle JDBC jars from Maven Central
7. Wires `dbeaver.ini` with the Kerberos JVM args from [../config/windows/dbeaver-jvm-args.example](../config/windows/dbeaver-jvm-args.example)

End state: `wks01` is a domain member, DBeaver is installed at `C:\Program Files\dbeaver\`, jars are at `C:\Users\Public\jdbc\oracle\23.3\`, the desktop has a DBeaver shortcut.

## Post-provision steps (in the VirtualBox console)

The provisioner runs as the local `vagrant` user (used by Vagrant's WinRM). To actually use the system as alice:

1. Open the `wks01` console window in VirtualBox.
2. **Sign out** of the `vagrant` session (Start → user icon → Sign out).
3. On the lock screen, click **Other user** → enter `MYLAB\alice` and her password.
4. Once on the desktop, open PowerShell and run `klist`. You should see something like:

   ```
   Cached Tickets: (2)

   #0>     Client: alice @ MYLAB.LOCAL
           Server: krbtgt/MYLAB.LOCAL @ MYLAB.LOCAL
           KerbTicket Encryption Type: AES-256-CTS-HMAC-SHA1-96
           Ticket Flags 0x40e10000 -> forwardable renewable initial pre_authent name_canonicalize
           Start Time: ...  End Time: ...  Renew Time: ...
   ```

   That's the LSA cache view (Windows native `klist`, not MIT). If you have MIT KfW installed too, MIT `klist` will show the FILE cache, which will be empty unless you also `kinit`'d separately.

5. Double-click the DBeaver desktop shortcut.

## DBeaver setup (one-time, in the UI as alice)

The DBeaver setup itself is identical to [docs/07](07-dbeaver-oracle-driver.md) and [docs/08](08-dbeaver-connection.md) — same driver registration, same connection settings, same Driver properties. Only differences:

- Jar paths are at `C:\Users\Public\jdbc\oracle\23.3\` (provisioner staged them there for any user).
- You don't need `KRB5CCNAME` set anywhere — JVM uses LSA.
- You don't need to `kinit` before connecting. Just open DBeaver after logon.

## Verification

```powershell
PS> klist                                              # show LSA tickets
PS> klist tickets                                      # alternate syntax on some Windows versions
PS> Get-WindowsCapability -Online -Name 'Rsat*'        # optional, for setspn queries
PS> setspn -Q oracle/ora01.mylab.local@MYLAB.LOCAL     # should return CN=svc-ora01,...
```

Then in DBeaver, open the saved `ORCLPDB1` connection → Test Connection → green. SQL editor:

```sql
SELECT USER,
       SYS_CONTEXT('USERENV','AUTHENTICATION_METHOD') AS AUTH,
       SYS_CONTEXT('USERENV','OS_USER')               AS OS_USER
FROM DUAL;
```

Expected:

| USER | AUTH | OS_USER |
|---|---|---|
| `ALICE@MYLAB.LOCAL` | `KERBEROS` | `alice` |

The `OS_USER` column now shows `alice` (not blank or some other value) because Oracle can read the Kerberos-authenticated OS user identity — a small but real benefit of the domain-joined client.

## Switching users

Just sign out and back in as `MYLAB\bob` or `MYLAB\carol`. New logon → new LSA TGT → DBeaver picks up the new identity automatically. Run `SELECT USER FROM DUAL` again to confirm.

## When this *won't* work

- **`allowtgtsessionkey=1` not applied.** JVM gets `ORA-12638: Credential retrieval failed` because Windows hides the TGT session key from user-mode by default. The provisioner sets this; if you ever revert it, the next reboot kills the DBeaver path.
- **Time drift.** Still applies; sssd / kdc still want sub-5-minute skew. The provisioner sets `w32tm` to sync from `ad1`. If `ad1` itself drifts (suspended VM), both VMs need to resync. See [troubleshooting.md#clock-skew](../troubleshooting.md#clock-skew).
- **GPO pushed to `wks01` that revokes `allowtgtsessionkey` or strips the lab Root CA.** Possible if you accidentally apply a real corporate GPO via your AD setup. Lab `ad1` has the default empty GPOs, so unlikely unless you customize.

## Operational notes

| Action | Command (as Domain Admin on ad1) |
|---|---|
| Add a new test user | `New-ADUser -Name 'dave' -UserPrincipalName 'dave@MYLAB.LOCAL' -AccountPassword (Read-Host -AsSecureString) -Enabled $true` |
| Verify alice's logon works | RDP into `wks01` as `MYLAB\alice`, or use the VirtualBox console |
| Rotate `allowtgtsessionkey` | Already set; check with `reg query HKLM\SYSTEM\CurrentControlSet\Control\Lsa\Kerberos\Parameters /v allowtgtsessionkey` |
| Remove `wks01` from AD before destroying VM | `Get-ADComputer wks01 \| Remove-ADComputer -Confirm:$false` |
