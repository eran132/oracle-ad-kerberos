# AD setup ticket — Oracle Kerberos + AD-group authorization

**To:** AD / Windows operations team
**From:** Oracle DBA
**Request:** create the AD objects below so an Oracle 19c database can authenticate AD users via Kerberos and use AD security groups to grant database privileges. **No Oracle account, no Oracle password, no schema extension. Plain `New-ADUser` + `setspn` + `ktpass` + `New-ADGroup`. ~10 minutes of work.**

---

## Values to confirm with the requester before running

Substitute everywhere in the commands below:

| Placeholder | Confirmed value |
|---|---|
| **AD realm** (UPPER) / DNS domain | `MYLAB.LOCAL` / `mylab.local` |
| **DC FQDN** | `ad1.mylab.local` |
| **Oracle host FQDN** | `ora01.mylab.local` |
| **Oracle service principal** | `oracle/ora01.mylab.local@MYLAB.LOCAL` |
| **SPN service account name** | `svc-ora01` |
| **LDAP bind service account name** | `svc-ora-ldap` |
| **AD groups to create** | `oracle-readers`, `oracle-writers` |
| **Groups OU** | `OU=Groups,DC=mylab,DC=local` |
| **SPN account password** (long random, store in your secrets vault) | _supplied separately_ |
| **LDAP account password** (long random, store in your secrets vault) | _supplied separately_ |

---

## Run on a Domain Controller as Domain Admin, in this order

```powershell
Import-Module ActiveDirectory

# ============================================================================
# 1) SPN service account: svc-ora01
#    Holds the Oracle Kerberos service principal. Its long-term key becomes
#    the keytab on the Oracle server. No human ever logs in as this account.
#
#    The password set HERE is a throwaway placeholder -- AD won't create an
#    enabled account with no password, but step 2's ktpass immediately resets
#    it to the value that actually counts. Do not record this one.
#    Idempotent: if the account already exists we normalize it instead of
#    failing (safe to re-run for rebuilds / fixes).
# ============================================================================
$throwaway = ConvertTo-SecureString ([guid]::NewGuid().ToString() + 'Aa1!') -AsPlainText -Force
if (Get-ADUser -Filter "SamAccountName -eq 'svc-ora01'" -ErrorAction SilentlyContinue) {
  Write-Host "svc-ora01 exists -- normalizing (password set by ktpass in step 2)."
  Enable-ADAccount -Identity svc-ora01
  Set-ADUser -Identity svc-ora01 `
    -UserPrincipalName "svc-ora01@MYLAB.LOCAL" `
    -PasswordNeverExpires $true -CannotChangePassword $true
} else {
  New-ADUser `
    -Name "svc-ora01" `
    -SamAccountName "svc-ora01" `
    -UserPrincipalName "svc-ora01@MYLAB.LOCAL" `
    -DisplayName "Oracle Kerberos SPN service (ora01)" `
    -Description "Holds SPN oracle/ora01.mylab.local. Keytab lives on ora01:/etc/oracle/keytabs/" `
    -AccountPassword $throwaway `
    -Enabled $true `
    -PasswordNeverExpires $true `
    -CannotChangePassword $true `
    -Path "CN=Users,DC=mylab,DC=local"
}

# Force AES-256 only (no RC4)
Set-ADUser -Identity svc-ora01 -KerberosEncryptionType "AES256"


# ============================================================================
# 2) Register the SPN AND emit the keytab in one step.
#    ktpass ALWAYS resets the account password and bumps the KVNO -- that is
#    how it derives the Kerberos key it writes into the keytab. The value you
#    type at the -pass * prompt is the AUTHORITATIVE one: store it in the
#    password vault, the next keytab rotation needs it.
#
#    -pass *  => ktpass prompts (hidden); password never hits the command
#                line, console history, or the process list.
#
#    Already exists / this is a rotation: running this exact command is the
#    right thing -- create and rotate converge here. The only failure case is
#    a DUPLICATE SPN; see the cleanup just below the verify line.
# ============================================================================
ktpass `
  -princ oracle/ora01.mylab.local@MYLAB.LOCAL `
  -mapuser MYLAB\svc-ora01 `
  -pass * `
  -crypto AES256-SHA1 `
  -ptype KRB5_NT_PRINCIPAL `
  -out C:\temp\ora01.keytab

# Verify there is exactly ONE account with this SPN:
setspn -Q oracle/ora01.mylab.local
# Expected single line: CN=svc-ora01,CN=Users,DC=mylab,DC=local
#
# If it returns MORE THAN ONE account, or an account that is NOT svc-ora01,
# remove the SPN from each wrong holder then re-run the ktpass command above:
#   setspn -D oracle/ora01.mylab.local <WRONG-account>


# ============================================================================
# 3) LDAP bind service account: svc-ora-ldap
#    The Oracle database binds to AD over LDAPS with this account to read
#    user group memberships. No elevated privileges needed -- default
#    "Domain Users" Read access is sufficient.
#
#    UNLIKE svc-ora01, this account has NO keytab. Its password is used
#    directly by Oracle (loaded into the wallet on ora01), so the password
#    set here IS authoritative -- store it in the vault and give it to the
#    DBA out-of-band. Idempotent guard: on re-run we DO NOT touch the
#    password (changing it without updating the wallet breaks the sync).
# ============================================================================
if (Get-ADUser -Filter "SamAccountName -eq 'svc-ora-ldap'" -ErrorAction SilentlyContinue) {
  Write-Host "svc-ora-ldap exists -- leaving password untouched (rotate via the"
  Write-Host "DBA runbook Part B3, which also updates the Oracle wallet)."
  Enable-ADAccount -Identity svc-ora-ldap
  Set-ADUser -Identity svc-ora-ldap `
    -UserPrincipalName "svc-ora-ldap@MYLAB.LOCAL" `
    -PasswordNeverExpires $true -CannotChangePassword $true
} else {
  $ldapPw = Read-Host -AsSecureString "NEW password for svc-ora-ldap (vault + give to DBA)"
  New-ADUser `
    -Name "svc-ora-ldap" `
    -SamAccountName "svc-ora-ldap" `
    -UserPrincipalName "svc-ora-ldap@MYLAB.LOCAL" `
    -DisplayName "Oracle LDAPS bind account for AD-group sync" `
    -Description "Used by ora01's PL/SQL ad_sync package to read memberOf over LDAPS-636" `
    -AccountPassword $ldapPw `
    -Enabled $true `
    -PasswordNeverExpires $true `
    -CannotChangePassword $true `
    -Path "CN=Users,DC=mylab,DC=local"
}


# ============================================================================
# 4) AD security groups.
#    Members of these will receive Oracle role grants (managed entirely on
#    the database side -- no further AD changes needed when permissions
#    change inside Oracle).
# ============================================================================
if (-not (Get-ADOrganizationalUnit -Filter 'Name -eq "Groups"' -SearchBase "DC=mylab,DC=local" -ErrorAction SilentlyContinue)) {
  New-ADOrganizationalUnit -Name "Groups" -Path "DC=mylab,DC=local"
}

New-ADGroup -Name "oracle-readers" -GroupScope Global -GroupCategory Security `
  -Path "OU=Groups,DC=mylab,DC=local" `
  -Description "Members get SELECT on ORCLPDB1"

New-ADGroup -Name "oracle-writers" -GroupScope Global -GroupCategory Security `
  -Path "OU=Groups,DC=mylab,DC=local" `
  -Description "Members get SELECT/INSERT/UPDATE/DELETE on ORCLPDB1"


# ============================================================================
# 5) Export the Enterprise Root CA certificate so the Oracle wallet can trust
#    LDAPS responses from the DC. Hand this file to the Oracle DBA.
#    (Skip this step if your environment shares the corporate root CA via
#    other means and the DBA already has it.)
# ============================================================================
$ca = Get-CACertificate
$ca.RawData | Set-Content -Encoding Byte C:\temp\root-ca.cer
certutil -encode C:\temp\root-ca.cer C:\temp\root-ca.pem
# Deliverables to the DBA:  C:\temp\root-ca.cer  (DER)  and/or  .pem  (Base64)
```

---

## Deliverables to the Oracle DBA after running

| File / value | How to provide |
|---|---|
| `C:\temp\ora01.keytab` (binary, ~200 bytes) | Secure file transfer (SFTP / signed-email attachment / corp file share). **Treat as a private key — delete from `C:\temp\` after handover.** |
| `C:\temp\root-ca.cer` and/or `.pem` | Same channel; public cert, lower sensitivity. |
| `svc-ora-ldap` UPN (`svc-ora-ldap@MYLAB.LOCAL`) and **its password** | Out-of-band (password vault, sealed envelope, whatever your standard secret-handover process is). The DBA loads the password into the Oracle wallet; it is never stored in a config file. |

---

## Validation checklist (run on the DC before closing the ticket)

```powershell
# 4 AD objects present and configured:
Get-ADUser  svc-ora01    -Properties UserPrincipalName, ServicePrincipalNames, msDS-SupportedEncryptionTypes
Get-ADUser  svc-ora-ldap -Properties UserPrincipalName, Enabled, msDS-SupportedEncryptionTypes
Get-ADGroup oracle-readers
Get-ADGroup oracle-writers

# Expected on svc-ora01:
#   ServicePrincipalNames        : {oracle/ora01.mylab.local}
#   msDS-SupportedEncryptionTypes: 16          (= AES256 only)
#   UserPrincipalName            : svc-ora01@MYLAB.LOCAL

# No duplicate SPNs anywhere in the forest:
setspn -X
# Expected: "found 0 group of duplicate SPNs."

# Keytab contains the right principal at AES256:
ktab.exe -l -e -t -k C:\temp\ora01.keytab
# Expected one entry:
#   oracle/ora01.mylab.local@MYLAB.LOCAL
#   KVNO 2 (or higher after rotations)
#   Encryption type: AES256-CTS-HMAC-SHA1-96

# LDAPS works on the DC and presents the Enterprise CA-issued cert:
$d="ad1.mylab.local"; $p=636
$tcp=New-Object Net.Sockets.TcpClient($d,$p)
$ssl=New-Object Net.Security.SslStream($tcp.GetStream(),$false,{$true})
$ssl.AuthenticateAsClient($d)
([Security.Cryptography.X509Certificates.X509Certificate2]$ssl.RemoteCertificate) |
  Select-Object Subject, Issuer, NotBefore, NotAfter
$ssl.Close(); $tcp.Close()
# Expected: Subject = CN=ad1.mylab.local; Issuer = your Enterprise Root CA.
```

If all four blocks pass, the AD side is done. The DBA installs the keytab + Root CA cert on the Oracle host, runs the database-side installer, and validates from a client. Ticket can be closed.

---

## Day-2: how this gets used after handover

Once the database side is configured, **the only AD-side ongoing work** is normal group membership management:

```powershell
# Grant a person SELECT access in Oracle:
Add-ADGroupMember -Identity oracle-readers -Members <samAccountName>

# Revoke it:
Remove-ADGroupMember -Identity oracle-readers -Members <samAccountName>

# Move them from reader to writer:
Remove-ADGroupMember -Identity oracle-readers -Members <samAccountName>
Add-ADGroupMember    -Identity oracle-writers -Members <samAccountName>
```

The Oracle database picks up changes within 10 minutes (scheduled sync) or instantly on the user's next database login (logon trigger). No DBA coordination required for routine membership changes.

For password rotations of `svc-ora01` (and the matching keytab) or `svc-ora-ldap`, contact the DBA — see the rotation procedures in the full runbook the DBA has on hand.

---

## Reference

This ticket implements the **AD side only**. Full lab documentation is at the Oracle DBA's repository under `docs/19-ad-admin-runbook.md` (verbose version of this ticket) and `RECIPE.md` (Oracle-side mirror).
