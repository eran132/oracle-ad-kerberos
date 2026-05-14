# 03 · AD service account, SPN, and keytab — recap

You ran the scripts in [02 · Lab prereqs](02-prereqs-lab-bringup.md). This chapter explains **what they did and why**, so when something needs adjusting (e.g. SPN moved, enctype changed, keytab rotated) you can do it without re-reading the scripts each time.

The authoritative scripts live in the sibling repo:
- [..\..\..\tableau_ad_oracle\scripts\ad-create-lab-accounts.ps1](../../tableau_ad_oracle/scripts/ad-create-lab-accounts.ps1)
- [..\..\..\tableau_ad_oracle\scripts\ktpass-keytabs.ps1](../../tableau_ad_oracle/scripts/ktpass-keytabs.ps1)

---

## The service account `svc-ora01`

Equivalent of:

```powershell
New-ADUser -Name "svc-ora01" -SamAccountName "svc-ora01" `
    -UserPrincipalName "svc-ora01@MYLAB.LOCAL" `
    -AccountPassword $OraPassword -PasswordNeverExpires $true `
    -Enabled $true
```

Why a dedicated user (not a computer account, not the Oracle server's host account):
- Oracle reads its keytab as the `oracle` OS user; it does not run as `LocalSystem` or as `ora01$`. So a regular user account is the natural fit.
- `PasswordNeverExpires` because the password is the key — rotating it without regenerating the keytab breaks auth ([troubleshooting.md#krb-ap-err-modified](../troubleshooting.md#krb-ap-err-modified)).
- Keep the password long, random, and only ever readable from the `ktpass` invocation. The sibling-lab script reads it from a SecureString blob.

### Encryption types

By default, AD user accounts have `msDS-SupportedEncryptionTypes` set to a value that excludes AES (depending on functional level). For a service principal you typically want **only** AES:

```powershell
Set-ADUser svc-ora01 -KerberosEncryptionType AES256
# Or, explicit bitmask:
Set-ADUser svc-ora01 -Replace @{ "msDS-SupportedEncryptionTypes" = 0x18 }
# 0x10 = AES256-CTS-HMAC-SHA1-96
# 0x08 = AES128-CTS-HMAC-SHA1-96
# 0x18 = both
```

You **must reset the account's password after changing enctypes**, otherwise the stored key is still in the old enctype. See [troubleshooting.md#enctype-mismatch](../troubleshooting.md#enctype-mismatch).

The verification script [scripts/windows/Test-SpnLookup.ps1](../scripts/windows/Test-SpnLookup.ps1) checks the AES256 bit via RSAT `Get-ADUser`.

## The SPN

Two SPNs are registered, both on `svc-ora01`:

```powershell
setspn -S "oracle/ora01.mylab.local" svc-ora01    # FQDN — primary
setspn -S "oracle/ora01"             svc-ora01    # short name — convenience
```

Why two:
- The Oracle listener / sqlnet.ora knows itself by FQDN (`ora01.mylab.local`); any client looking up the service ticket uses the FQDN. This is the SPN that actually matters.
- The short-name variant covers cases where a client (or DNS suffix list) gives an unqualified `ora01`. Cheap insurance.

Why **not** `oracle/192.168.56.20` (IP-form SPNs): Kerberos does not officially support IP-form principals. The KDC may issue them, but enctype handling and ticket lifetime hooks get weird. Always use names.

### Uniqueness

A given SPN must appear on exactly one AD object. `setspn -X` flags duplicates. Duplicates cause `KRB_AP_ERR_MODIFIED` because the KDC picks one account's key and the service uses the other's. See [troubleshooting.md#duplicate-spn](../troubleshooting.md#duplicate-spn).

## The keytab

The keytab is a file holding the long-term Kerberos key for the service principal. It lives on the Oracle host and lets Oracle decrypt incoming service tickets without knowing the AD account's password interactively.

`ktpass.exe` command from the sibling-lab script:

```powershell
ktpass `
  -princ "oracle/ora01.mylab.local@MYLAB.LOCAL" `
  -mapuser "MYLAB\svc-ora01" `
  -pass $oraclePasswordCleartext `
  -crypto AES256-SHA1 `
  -ptype KRB5_NT_PRINCIPAL `
  -out C:\path\ora01.keytab
```

Effect on AD:
- Sets `svc-ora01`'s password to the supplied value.
- Sets `userPrincipalName` to `oracle/ora01.mylab.local@MYLAB.LOCAL` *(this is the side-effect that bites people — see below)*.
- Writes the keytab file containing the AES256 key.

> **`ktpass` side-effect: `userPrincipalName` clobbering.** By default `ktpass` overwrites the UPN of the mapped user to match the service principal. For a dedicated service account that's fine, but if you ever ran `ktpass` against a real human user, their UPN would no longer be `alice@MYLAB.LOCAL` and they'd suddenly fail to log on to Windows. This is why we have a dedicated `svc-ora01`.

### Where the keytab lives on Oracle

```
/etc/oracle/keytabs/ora01.keytab    owner: oracle:oinstall    mode: 0640
```

Permissions matter:
- World-readable keytabs are an audit finding — the AES key is in there.
- Wrong owner (e.g. `root:root`) means the Oracle process can't open it; `sqlnet.log` shows "permission denied".

### Inspecting the keytab

On Oracle:
```bash
[ora01]$ sudo -u oracle klist -kte /etc/oracle/keytabs/ora01.keytab
Keytab name: FILE:/etc/oracle/keytabs/ora01.keytab
KVNO Timestamp           Principal
---- ------------------- ----------------------------------------------------
   2 05/01/2026 10:00:00 oracle/ora01.mylab.local@MYLAB.LOCAL (aes256-cts-hmac-sha1-96)
```

Three things to verify:
1. **Principal name** matches exactly the SPN registered in AD (case-sensitive).
2. **KVNO** matches what `kvno oracle/ora01.mylab.local@MYLAB.LOCAL` reports on the Windows host. Drift means AD's password was changed without re-issuing the keytab (or vice versa).
3. **Enctype** is `aes256-cts-hmac-sha1-96`. If you see `arcfour-hmac` (RC4), `krb5.ini` and `msDS-SupportedEncryptionTypes` settings disagree.

## Putting it together — the steady state

```
AD object svc-ora01
├─ UPN:        oracle/ora01.mylab.local@MYLAB.LOCAL  (set by ktpass)
├─ SPNs:       oracle/ora01.mylab.local
│              oracle/ora01
├─ Enctypes:   AES256 + AES128
└─ Password:   (matches the key inside the keytab)

Oracle host /etc/oracle/keytabs/ora01.keytab
└─ kvno=N, principal=oracle/ora01.mylab.local@MYLAB.LOCAL, AES256
```

When everything is aligned:
- Windows host runs `kinit alice@MYLAB.LOCAL` → AS-REQ to KDC, gets TGT.
- `kvno oracle/ora01.mylab.local@MYLAB.LOCAL` → KDC encrypts an ST using **`svc-ora01`'s AD password** (which became the AES256 key).
- Oracle reads the ST, uses the **same AES256 key from its keytab** to decrypt. Match → session granted.

Next: [04 · Oracle server-side Kerberos](04-oracle-server-kerberos.md).
