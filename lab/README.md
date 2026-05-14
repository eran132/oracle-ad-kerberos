# `lab/` — workstation VM for the DBeaver/Kerberos flow

This is a Vagrantfile + provisioners that builds **`wks01.mylab.local`**, a Windows 11 client VM joined to the lab AD domain. It's the canonical workstation for testing the DBeaver → Oracle Kerberos path **without touching your real laptop**.

After `vagrant up wks01` finishes:

1. You log into the VirtualBox console for `wks01` as **`MYLAB\alice`** (or `bob`, `carol`).
2. Windows obtains a TGT into LSA at logon automatically.
3. Double-click the DBeaver shortcut on the Desktop.
4. DBeaver's JVM reads the TGT from LSA (via SSPI/JGSS, enabled by the `allowtgtsessionkey` reg tweak that the provisioner applied).
5. Connect to `orclpdb1` on `ora01.mylab.local:1521`. No `kinit`, no password.

---

## Prerequisites

| Thing | Why |
|---|---|
| VirtualBox 7.x | Provider |
| Vagrant 2.4+ | Configuration |
| `gusztavvargadr/windows-11` box (~10 GB) | Base image. Vagrant fetches it the first time. |
| `ad1.mylab.local` running and reachable | Domain join target |
| Domain Administrator credentials | Add-Computer needs to authenticate. Passed in via env var below — never written to disk. |
| Lab Root CA at `../config/windows/trust/mylab-root-ca.cer` | Pinned to the VM's trust store during provisioning |
| ~12 GB free disk, ~4 GB free RAM | VirtualBox sizing |

## Bring it up

From a PowerShell window in this `lab/` directory:

```powershell
PS> $env:AD_ADMIN_USER = 'mylab\Administrator'
PS> $env:AD_ADMIN_PW   = '<your Administrator password — typed, not pasted from a file>'
PS> vagrant up wks01
```

The password lives **only** in the current process environment. The Vagrantfile reads it via `ENV['AD_ADMIN_PW']` and forwards it to the provisioner. Nothing is persisted to disk. Close the PowerShell window when you're done and the secret is gone.

What happens automatically:

1. **Phase 1** ([provision/01-os-prep-and-join.ps1](provision/01-os-prep-and-join.ps1)):
   - Pin static DNS to `192.168.56.10` on the host-only NIC
   - Sync time to `ad1` (Kerberos requires < 5 min skew)
   - Add hosts file fallback entries
   - Import `mylab-root-ca` into `Cert:\LocalMachine\Root`
   - Place `krb5.ini` at `C:\ProgramData\MIT\Kerberos5\krb5.ini` *(for the rare case you want MIT KfW as a fallback)*
   - Apply the `allowtgtsessionkey` LSA registry tweak
   - Rename computer to `wks01`, `Add-Computer -DomainName mylab.local`, reboot
2. **Phase 2** ([provision/02-install-dbeaver.ps1](provision/02-install-dbeaver.ps1)):
   - Download DBeaver CE portable zip from `dbeaver.io`, extract to `C:\Program Files\dbeaver\`
   - Stage Oracle JDBC jars at `C:\Users\Public\jdbc\oracle\23.3\` (`ojdbc8.jar`, `oraclepki.jar`, `osdt_core.jar`, `osdt_cert.jar`)
   - Inject Kerberos JVM args into `dbeaver.ini`
   - Create a Public Desktop shortcut to `dbeaver.exe`

Provisioning takes ~10–15 min after the box download finishes.

### Air-gapped variant (no internet on the target)

If `wks01` cannot reach `dbeaver.io` / `repo1.maven.org`, switch to offline mode:

```powershell
PS> # 1. Stage on a build PC that DOES have internet:
PS> .\tools\stage-offline-bundle.ps1                  # ~140 MB into lab\bundle\

PS> # 2. Sneakernet the entire lab\bundle\ to the target.

PS> # 3. On the target:
PS> $env:LAB_OFFLINE = '1'
PS> $env:AD_ADMIN_PW = '<the Administrator password>'
PS> vagrant up wks01
```

The Vagrantfile detects `LAB_OFFLINE=1`, uploads `bundle/*` to `C:\Windows\Temp\bundle\`, and runs [provision/02-install-dbeaver-offline.ps1](provision/02-install-dbeaver-offline.ps1) (verifies checksums, never touches the internet). Full workflow in [../docs/14-air-gapped.md](../docs/14-air-gapped.md).

## What you do after `vagrant up` completes

1. **Switch user in the VirtualBox console.** The provisioner leaves you signed in as `vagrant`; sign out and sign back in as `MYLAB\alice` (or any AD user from `ad-create-lab-accounts.ps1`).
2. **Verify LSA has a ticket:** open PowerShell as alice, run `klist`. Should show `krbtgt/MYLAB.LOCAL` plus any service tickets the OS has cached.
3. **Open DBeaver from the Desktop shortcut.**
4. **Register the four jars** under Database → Driver Manager → Oracle → Edit Driver → Libraries:
   - `C:\Users\Public\jdbc\oracle\23.3\ojdbc8.jar`
   - `oraclepki.jar`, `osdt_core.jar`, `osdt_cert.jar`
5. **Create the connection** as documented in [../docs/08-dbeaver-connection.md](../docs/08-dbeaver-connection.md). Username **blank**; Driver properties set to:
   - `oracle.net.authentication_services = (KERBEROS5)`
   - `oracle.net.kerberos5_mutual_authentication = true`
6. **Test Connection.** Expected: green dialog showing `Oracle Database 19c`.

## Lifecycle commands

| Command | Effect |
|---|---|
| `vagrant up wks01` | Boot + provision (idempotent — re-running is safe) |
| `vagrant halt wks01` | Graceful shutdown |
| `vagrant reload wks01` | Restart |
| `vagrant destroy wks01` | Delete the VM (also removes the AD computer object if you also `Remove-Computer` first) |
| `vagrant provision wks01` | Re-run provisioners on the existing VM |

## Why a separate VM and not your laptop

- Your laptop is joined to a different (corporate) AD domain. Windows can only be in one domain.
- Running `kinit` from MIT KfW on a laptop works but requires re-entering alice's password every TGT lifetime.
- A domain-joined workstation gives you **interactive logon = TGT** automatically, plus realistic UX matching what an analyst would experience.
- Keeps lab artifacts (root CAs, registry tweaks, DBeaver install) isolated from corporate-managed state.

## Memory note

Box was provisioned with **3 GB RAM** — below Microsoft's documented 4 GB minimum for Windows 11. It works for the DBeaver test scenario (one connection, light queries) but you may see noticeable lag. To bump it after the fact:

```powershell
PS> vagrant halt wks01
PS> # Edit Vagrantfile, change vb.memory = 4096
PS> vagrant up wks01
```

## What's NOT in the provisioner (and why)

- **No saved DBeaver connection profile.** DBeaver's workspace JSON is fiddly and version-sensitive; cleaner to create the connection manually once.
- **No alice keytab automation.** Not needed — domain join means LSA carries the TGT. The keytab pattern from [../docs/05](../docs/05-windows-client-mit-krb.md) is the *non-domain-joined* fallback.
- **No Oracle Instant Client.** Optional smoke-test only; not on the critical path. Add it manually if you want `sqlplus` parity.
