# 02 · Lab prereqs and bring-up

This chapter lists what must be running before any of the Kerberos chapters apply. The provisioning itself is owned by the sibling lab — we just describe the desired state and link to the scripts that produce it.

---

## Desired state at the end of this chapter

- `ad1` VM running on 192.168.56.10 (Windows Server 2022, DC for `mylab.local`).
- `ora01` VM running on 192.168.56.20 (RHEL/Rocky 9, Oracle Database 19c installed, CDB `ORCLCDB` with PDB `ORCLPDB1` open, listener on 1521).
- VirtualBox host-only network `vboxnet0` = `192.168.56.0/24` reachable from the Windows host (`192.168.56.1`).
- Domain user accounts created in AD: `alice`, `bob`, `carol`. Service account `svc-ora01` created with SPN `oracle/ora01.mylab.local`.
- Time on `ad1`, `ora01`, and the Windows host within 60 seconds of each other.

## Host requirements

| Resource | Minimum |
|---|---|
| Windows host RAM | 16 GB (32 GB recommended; sibling-lab `LAB_STATUS.md` confirms one VM at a time on 32 GB) |
| Disk | ~80 GB free for both VMs + Oracle DB media (`LINUX.X64_193000_db_home.zip` for 19c, or `LINUX.X64_213000_db_home.zip` for 21c) |
| VirtualBox | 7.x with the host-only adapter `vboxnet0` configured for 192.168.56.0/24, **DHCP disabled** |
| RSAT (optional) | `Get-ADUser`, `setspn` enctype checks in [scripts/windows/Test-SpnLookup.ps1](../scripts/windows/Test-SpnLookup.ps1) |

## Bring up the VMs

Run from the **sibling** repo:

```powershell
PS> cd C:\Users\<you>\Documents\tableau_ad_oracle
PS> vagrant up ad1
PS> vagrant up ora01
```

The Vagrantfile ([..\..\..\tableau_ad_oracle\Vagrantfile](../../tableau_ad_oracle/Vagrantfile)) wires up:

- IP assignments above
- Provisioning order: `rhel-prepare-mylab.sh` → `oracle21c-prereqs.sh` (Oracle install + realm-join are manual after first boot — see sibling-lab notes)
- 6 GB RAM / 2 vCPU for `ora01`

> **VM tip:** the sibling-lab `LAB_STATUS.md` notes "do NOT use headless mode" and "single VM at a time recommended." For this Oracle/DBeaver work, only `ad1` + `ora01` are needed; ignore `tab01` and `rhel97-test`.

## Verify the VMs from the Windows host

```powershell
PS> Test-NetConnection ad1.mylab.local  -Port 88     # KDC
PS> Test-NetConnection ad1.mylab.local  -Port 636    # LDAPS
PS> Test-NetConnection ora01.mylab.local -Port 1521  # Oracle listener
PS> w32tm /stripchart /computer:ad1.mylab.local /samples:3
```

All four should pass. If `Resolve-DnsName` fails, add to `C:\Windows\System32\drivers\etc\hosts`:

```
192.168.56.10  ad1.mylab.local  ad1
192.168.56.20  ora01.mylab.local ora01
```

(See [troubleshooting.md#dns-resolution](../troubleshooting.md#dns-resolution).)

## Provision AD users + Oracle service account

Run on `ad1` as Domain Admin:

```powershell
> .\scripts\ad-create-lab-accounts.ps1
```

That script (in the **sibling** repo: [..\..\..\tableau_ad_oracle\scripts\ad-create-lab-accounts.ps1](../../tableau_ad_oracle/scripts/ad-create-lab-accounts.ps1)) creates:

- Domain users `alice`, `bob`, `carol` for testing
- Service account `svc-ora01` with `PasswordNeverExpires`
- SPNs: `oracle/ora01.mylab.local` and `oracle/ora01` registered on `svc-ora01`
- (Ignore the Tableau-specific accounts `svc-tab-ldap`, `svc-tab-deleg` — they don't affect this runbook)

Verify from the Windows host:

```powershell
PS> setspn -Q oracle/ora01.mylab.local
# Existing SPN found!
# CN=svc-ora01,CN=Users,DC=mylab,DC=local
#     oracle/ora01.mylab.local
```

## Generate the Oracle keytab

Run on `ad1` as Domain Admin:

```powershell
> .\scripts\ktpass-keytabs.ps1
```

Output: a file `ora01.keytab` under that repo's `out\` directory. The script uses `-crypto AES256-SHA1 -ptype KRB5_NT_PRINCIPAL` and resets the `svc-ora01` password to match.

Copy to the Oracle host:

```powershell
PS> scp .\out\ora01.keytab vagrant@ora01.mylab.local:/tmp/
```

```bash
[ora01]$ sudo install -m 0640 -o oracle -g oinstall /tmp/ora01.keytab /etc/oracle/keytabs/ora01.keytab
[ora01]$ sudo -u oracle klist -kte /etc/oracle/keytabs/ora01.keytab
# Should show one entry with kvno N (note N for later)
```

## Join Oracle host to AD (one-time)

```bash
[ora01]$ sudo /home/vagrant/scripts/realm-join.sh
```
([..\..\..\tableau_ad_oracle\scripts\realm-join.sh](../../tableau_ad_oracle/scripts/realm-join.sh) — uses `realm join --membership-software=adcli` plus `sssd` + `oddjobd`.)

After completion, `id alice@mylab.local` on `ora01` should resolve to a POSIX UID. This is **not** strictly required for Kerberos auth to Oracle — Oracle does not consult sssd — but it's a useful sanity check that the AD trust is healthy.

## Apply Kerberos to Oracle

```bash
[ora01]$ sudo /home/vagrant/scripts/oracle21c-kerberos.sh
```
([..\..\..\tableau_ad_oracle\scripts\oracle21c-kerberos.sh](../../tableau_ad_oracle/scripts/oracle21c-kerberos.sh).)

This:
- Installs `sqlnet.ora` into `$ORACLE_HOME/network/admin/` with the keytab path baked in.
- Sets `OS_AUTHENT_PREFIX=''` so user names are not auto-prefixed.
- Creates `CREATE USER "ALICE@MYLAB.LOCAL" IDENTIFIED EXTERNALLY` (and `BOB`, `CAROL`) in the PDB `orclpdb1`.
- Grants `CREATE SESSION` to each.

## Server-side verification

Before moving to the Windows client, prove the auth path works **from the Oracle host itself**:

```bash
[ora01]$ /home/vagrant/scripts/keytab-check.sh
[ora01]$ /home/vagrant/scripts/user-oracle-ticket-check.sh alice
```

The second script does `kinit alice@MYLAB.LOCAL` (prompts) and runs `sqlplus /@ORCLPDB1` — `SELECT USER FROM DUAL` should print `ALICE@MYLAB.LOCAL`. If that fails, fix the server side first; nothing in chapters 05–09 will work otherwise.

## Done

The lab is in the correct state. Move on to [03 · AD and SPN setup](03-ad-and-spn-setup.md) (recap-only — you've already run those scripts) or jump to [05 · Windows client](05-windows-client-mit-krb.md) if you're done with the recap chapters.
