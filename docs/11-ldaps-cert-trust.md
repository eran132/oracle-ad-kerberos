# 11 · LDAPS and the lab root CA trust chain

Kerberos itself doesn't need TLS — the protocol negotiates its own AES-encrypted session keys over plain TCP 88. **But every other AD interaction in this lab uses LDAPS (port 636), and LDAPS requires a real PKI**: a Root CA, a server cert for the DC, and that Root CA pinned in every client's trust store.

This chapter documents the cert architecture and how to verify each link.

---

## The chain, end to end

```
   Root CA (self-signed)              <-- mylab-root-ca, lives on ad1
        │  signs
        v
   DC server cert                     <-- CN=ad1.mylab.local, auto-enrolled by AD CS
        │  presented over TLS
        v
   ad1.mylab.local:636                <-- NTDS / LDAP server picks up cert automatically
        │  validated against trust store
        v
   Windows host  +  ora01  +  Oracle JDK   (each holds mylab-root-ca as a trust anchor)
```

Specific values in the lab:

| Object | Where it lives | Cert details |
|---|---|---|
| **Root CA** | `Cert:\LocalMachine\My` on `ad1`, `Cert:\LocalMachine\Root` on every client | `CN=mylab-root-ca, DC=mylab, DC=local`, RSA-2048, SHA-256, valid 10 years |
| **DC cert** | `Cert:\LocalMachine\My` on `ad1` | `CN=ad1.mylab.local`, EKU `Server Authentication`, 1-year validity, auto-renewed by AD CS auto-enrollment |
| **Windows host trust** | `Cert:\LocalMachine\Root` | DER-encoded `mylab-root-ca.cer` imported from `config/windows/trust/mylab-root-ca.cer` |
| **ora01 system trust** | `/etc/pki/ca-trust/source/anchors/mylab-root-ca.pem` then `update-ca-trust` | PEM form |
| **ora01 Java trust** | `$ORACLE_HOME/jdk/jre/lib/security/cacerts`, alias `mylab-root-ca` | Imported via `keytool` |

## Why each side needs the trust anchor

| Side | Needs the Root CA because |
|---|---|
| **Windows host** | `Test-SpnLookup.ps1` and any LDAPS-based AD query (e.g., `Get-ADUser -Server ad1.mylab.local:636`) verifies the DC cert chain. Strict mode fails if the Root CA isn't pinned. |
| **ora01 (system)** | `realmd`/`sssd`/`adcli` use LDAPS to enumerate users on demand. `openssl s_client -connect ad1.mylab.local:636 -CAfile /etc/pki/tls/certs/ca-bundle.crt` is the canonical smoke test. |
| **ora01 (Oracle JDK)** | Any Oracle-side feature that does LDAP-S to AD (centrally managed users via OUD/Enterprise User Security, audit forwarding, etc.) reads from the JDK's `cacerts`. Not used by basic Kerberos auth, but the lab pins it for forward-compatibility. |
| **DBeaver (Windows)** | The JDBC thin driver uses **Kerberos** to talk to Oracle, not LDAPS — so DBeaver doesn't actually need the Root CA for the connection itself. However, the same JVM may be reused for AD-integrated lookups in driver extensions; pinning is harmless and consistent. |

## How the chain got built (one-time)

1. **Install AD CS** on `ad1` (Domain Controller):
   ```powershell
   Install-WindowsFeature AD-Certificate, ADCS-Cert-Authority -IncludeManagementTools
   ```
2. **Promote it to Enterprise Root CA** named `mylab-root-ca`:
   ```powershell
   Install-AdcsCertificationAuthority `
       -CAType EnterpriseRootCa `
       -CACommonName 'mylab-root-ca' `
       -CryptoProviderName 'RSA#Microsoft Software Key Storage Provider' `
       -KeyLength 2048 -HashAlgorithmName SHA256 `
       -ValidityPeriod Years -ValidityPeriodUnits 10 -Force
   ```
3. **Trigger DC auto-enrollment.** AD CS publishes the "Domain Controller" cert template by default; the DC enrolls itself within minutes. Force it with:
   ```powershell
   gpupdate /force /target:computer
   certutil -pulse
   Restart-Service NTDS -Force          # makes LDAPS pick up the new cert immediately
   ```
4. **Export the Root CA cert** so clients can pin it:
   ```powershell
   $ca = Get-ChildItem Cert:\LocalMachine\My | Where-Object { $_.Subject -like '*mylab-root-ca*' }
   $bytes = $ca.Export('Cert')
   [IO.File]::WriteAllBytes('C:\Windows\Temp\mylab-root-ca.cer', $bytes)
   ```
   And a PEM variant for Linux/Java:
   ```powershell
   $b64 = [Convert]::ToBase64String($bytes, 'InsertLineBreaks')
   "-----BEGIN CERTIFICATE-----`n$b64`n-----END CERTIFICATE-----" |
     Set-Content 'C:\Windows\Temp\mylab-root-ca.pem'
   ```

The lab keeps copies at:
- DER: [../config/windows/trust/mylab-root-ca.cer](../config/windows/trust/mylab-root-ca.cer)
- PEM: [../config/windows/trust/mylab-root-ca.pem](../config/windows/trust/mylab-root-ca.pem)

## Pinning the Root CA on each client

### Windows host

```powershell
PS> Import-Certificate `
        -FilePath .\config\windows\trust\mylab-root-ca.cer `
        -CertStoreLocation Cert:\LocalMachine\Root
```

Verify (strict chain):
```powershell
PS> $tcp = New-Object Net.Sockets.TcpClient('ad1.mylab.local', 636)
PS> $ssl = New-Object Net.Security.SslStream($tcp.GetStream(), $false)   # NO callback
PS> $ssl.AuthenticateAsClient('ad1.mylab.local')                          # throws if chain invalid
PS> $ssl.Dispose(); $tcp.Close()
```

The precheck script [../scripts/windows/Test-KerberosPrereqs.ps1](../scripts/windows/Test-KerberosPrereqs.ps1) does this for you and surfaces:
- `LdapsHandshake` — TLS handshake completed
- `LdapsCertSubject` / `LdapsCertIssuer` / `LdapsCertExpires` — server cert details
- `LdapsChainValid` — Boolean; `True` only when the Root CA is in `LocalMachine\Root`

### ora01 — system trust

```bash
[ora01]$ sudo install -m 0644 mylab-root-ca.pem /etc/pki/ca-trust/source/anchors/
[ora01]$ sudo update-ca-trust
[ora01]$ echo Q | openssl s_client -connect ad1.mylab.local:636 \
            -CAfile /etc/pki/tls/certs/ca-bundle.crt -servername ad1.mylab.local 2>&1 \
        | grep 'Verify return code'
# Expected: Verify return code: 0 (ok)
```

### ora01 — Oracle JDK cacerts

```bash
[ora01]$ ORACLE_HOME=/u01/app/oracle/product/19.0.0/dbhome_1
[ora01]$ sudo -u oracle $ORACLE_HOME/jdk/jre/bin/keytool \
            -import -trustcacerts -noprompt \
            -alias mylab-root-ca \
            -file mylab-root-ca.pem \
            -keystore $ORACLE_HOME/jdk/jre/lib/security/cacerts \
            -storepass changeit
```

Verify:
```bash
[ora01]$ sudo -u oracle $ORACLE_HOME/jdk/jre/bin/keytool -list \
            -alias mylab-root-ca \
            -keystore $ORACLE_HOME/jdk/jre/lib/security/cacerts \
            -storepass changeit
# trustedCertEntry, fingerprint SHA-256: 69:2C:A3:55:EF:77:2E:3F:65:D8:D9:15:7D:D9:63:C1:3D:C2:E8:A4:35:08:65:A4:B9:20:19:73:07:F7:9F:AE
```

## Rotation

| Cert | Lifetime | Renewal |
|---|---|---|
| Root CA (`mylab-root-ca`) | 10 years | Out of scope for normal ops. When near expiry, `certutil -renewcert`. |
| DC cert (`CN=ad1.mylab.local`) | 1 year | Auto-renewed by AD CS auto-enrollment ~6 weeks before expiry. To force, `certutil -pulse` on the DC. |
| Trust-anchor pins on clients | Same as Root CA | No action needed during DC cert renewal — chain stays valid as long as the Root is pinned. |

When the **Root CA itself** rotates, every client's trust store must be updated. Add the new Root, leave the old Root in place until all DC certs have rolled over, then remove the old one.

## Failure modes

The precheck distinguishes three LDAPS failure modes:

| Symptom | Likely cause | Fix anchor |
|---|---|---|
| `LdapsPort636 = False` | NTDS down, firewall blocking 636 | restart NTDS, check Windows Firewall |
| `LdapsPort636 = True` but `LdapsHandshake = False` ("connection forcibly closed") | DC has no Server Authentication cert in `LocalMachine\My` | [troubleshooting.md#ldaps-no-cert](../troubleshooting.md#ldaps-no-cert) |
| `LdapsHandshake = True` but `LdapsChainValid = False` (e.g. `RemoteCertificateChainErrors`) | Root CA not pinned in `LocalMachine\Root` on this host | [troubleshooting.md#ldaps-chain-untrusted](../troubleshooting.md#ldaps-chain-untrusted) |
| Strict chain validates but DBeaver `kinit` still fails | This is a Kerberos problem, not LDAPS. See [docs/06](06-windows-lsa-and-ccache.md) and [troubleshooting.md#gss-defective-token](../troubleshooting.md#gss-defective-token). |
