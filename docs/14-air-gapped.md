# 14 · Air-gapped lab provisioning

How to build and run the lab when the target environment cannot reach the public internet — no `dbeaver.io`, no `repo1.maven.org`, no `web.mit.edu`, no `api.github.com`. Everything moves over **one** sneakernet hop in a single ~140 MB bundle.

The end state is identical to chapter 13: a domain-joined Windows VM with DBeaver wired for Kerberos. The only difference is *zero* outbound HTTPS during provisioning.

---

## Two machines, one bundle

```
+--------------------+        +---------------------+
| Build PC           |        | Air-gapped target   |
| internet OK        |  USB   | (your isolated env) |
|                    |  ---->|                     |
| stage-offline-     |        | vagrant up wks01    |
| bundle.ps1         |        | LAB_OFFLINE=1        |
|                    |        |                     |
+--------------------+        +---------------------+
```

- **Build PC** doesn't need to be the same OS or even reachable from the lab. It just needs PowerShell, internet, and a copy of this repo.
- **Air-gapped target** is the Windows host you'll run VirtualBox + Vagrant on. It needs the lab VMs and a copy of this repo (with `lab/bundle/` populated) but no public-internet route.

Both machines should have **the same revision** of this repo. Easiest: `git bundle` it on the build PC, transfer alongside `lab/bundle/`, `git clone` from the bundle on the target.

---

## What's in the bundle, and why

Bundle layout (after running `tools/stage-offline-bundle.ps1`):

| File | Size | Source | Purpose |
|---|---|---|---|
| `dbeaver-portable.zip` | ~123 MB | `dbeaver.io/files/<ver>/dbeaver-ce-<ver>-win32.win32.x86_64.zip` | The DBeaver Community client itself. Portable variant — no installer, just unzip. |
| `ojdbc8.jar` | 6.7 MB | Maven `com.oracle.database.jdbc:ojdbc8:23.3.0.23.09` | Oracle JDBC thin driver. `oracle.jdbc.OracleDriver` lives here. |
| `oraclepki.jar` | 470 KB | Maven `com.oracle.database.security:oraclepki:23.3.0.23.09` | Implements the Kerberos5 client-side handler (`oracle.security.o5logon.O5LoginClientHelper`). Without it: `NoClassDefFoundError` on first KERBEROS5 connect. |
| `osdt_core.jar` | 305 KB | Maven `com.oracle.database.security:osdt_core:21.9.0.0` | ASN.1 + crypto primitives called by `oraclepki` when packaging the AP-REQ token. |
| `osdt_cert.jar` | 206 KB | Maven `com.oracle.database.security:osdt_cert:21.9.0.0` | X.509 path / CRL classes referenced transitively at `oraclepki` class init. |
| `mylab-root-ca.cer` / `.pem` | < 2 KB total | Exported from AD CS on `ad1` | The lab Root CA. Pinned in every client's trust store; see [docs/11](11-ldaps-cert-trust.md). |
| `corp-proxy-CAs/*.crt` | < 5 KB each | Pulled from `../tableau_ad_oracle/ca/` | Bluecoat / Symantec roots. **Only relevant if your air-gapped network still has a corporate inspection proxy** (e.g. an enterprise lab subnet). Skip if your network is truly internet-isolated. |
| `kfw-4.1-amd64.msi` | 10.6 MB | `web.mit.edu/kerberos/dist/kfw/4.1/kfw-4.1-amd64.msi` | Optional. Only needed if you'll also use a **non-domain-joined** Windows client (like your laptop in chapter 05). For wks01 alone, skip this — Windows ships its own Kerberos stack. |
| `checksums.txt` | < 1 KB | Generated | SHA-256 manifest. The offline provisioner verifies every file's hash before extracting. |

Total: **~140 MB** baseline, **~151 MB** with MIT KfW.

The set is **deliberately minimal**. See [docs/07](07-dbeaver-oracle-driver.md) §5 and [docs/14](#why-only-four-jars) for the per-jar justification — every other artifact in `ojdbc8-full.tar.gz` (ucp.jar, simplefan.jar, xdb.jar, …) is irrelevant to single-connection Kerberos auth from DBeaver.

---

## Step-by-step

### On the build PC (online)

1. Clone or copy this repo to a working directory.
2. Run the staging helper:

   ```powershell
   PS> cd path\to\oracle_Ad_kerberos
   PS> .\lab\tools\stage-offline-bundle.ps1
   ```

   With MIT KfW (if you also want offline install for a non-joined client):

   ```powershell
   PS> .\lab\tools\stage-offline-bundle.ps1 -IncludeMitKfw
   ```

   The script:
   - Resolves the latest DBeaver Community portable URL via the GitHub releases API + dbeaver.io HEAD probes
   - Downloads to `lab\bundle\`
   - Fetches the four Oracle jars from Maven Central
   - Copies `mylab-root-ca.cer/.pem` from `config\windows\trust\` (if AD CS has been built per chapter 11)
   - Copies any `.crt` files from `..\tableau_ad_oracle\ca\` into `lab\bundle\corp-proxy-CAs\`
   - Emits `checksums.txt` (SHA-256 of every file)

3. Verify (optional but recommended):

   ```powershell
   PS> Get-Content .\lab\bundle\checksums.txt
   ```

4. Sneakernet the **entire `lab/` directory** (or just `lab/bundle/` if the target already has the repo) to the air-gapped network.

### On the air-gapped target

Prerequisites already in place (these are part of the *server-side* lab setup, not the offline workflow):

- VirtualBox 7.x installed
- Vagrant 2.4+ installed
- `gusztavvargadr/windows-11` box already added (run `vagrant box add` ONCE on the build PC, then copy `%USERPROFILE%\.vagrant.d\boxes\` over too — or use `vagrant box add --provider virtualbox <box-tarball>` if you transferred the .box file)
- `ad1` (Windows Server 2022 DC) running, AD CS configured per [chapter 11](11-ldaps-cert-trust.md)
- `ora01` (Linux + Oracle 19c) running per [chapter 02](02-prereqs-lab-bringup.md)

Then:

1. Drop `lab/bundle/` into your offline copy of the repo (it stays at the same relative path).
2. Open PowerShell in the `lab/` directory.
3. Set the offline switch + the AD admin password:

   ```powershell
   PS> $env:LAB_OFFLINE = '1'
   PS> $env:AD_ADMIN_PW = '<the Administrator password>'
   ```

4. `vagrant up wks01`.

The Vagrantfile detects `LAB_OFFLINE=1`, validates the bundle is complete (refuses to start otherwise with a clear list of missing files), uploads each blob into the guest at `C:\Windows\Temp\bundle\`, and runs [`provision/02-install-dbeaver-offline.ps1`](../lab/provision/02-install-dbeaver-offline.ps1) instead of the network-bound default.

The offline provisioner:
- Verifies every checksum in `checksums.txt` before extracting anything
- Extracts DBeaver portable to `C:\Program Files\dbeaver\`
- Stages the four jars to `C:\Users\Public\jdbc\oracle\23.3\`
- Injects Kerberos JVM args into `dbeaver.ini`
- **Writes an eclipse pref that disables update checks** so DBeaver doesn't pop dialogs on startup trying to phone home

### Verify the install didn't reach the internet

After provisioning, on the air-gapped target:

```powershell
PS> Get-NetTCPConnection -State Established | Where-Object { $_.RemoteAddress -notmatch '^(192\.168\.56\.|127\.|::1$|fe80::)' }
```

Should return nothing — every established connection on the target host is loopback or host-only-lab.

Inside `wks01` (sign in as `MYLAB\alice`, open PowerShell):

```powershell
PS> Get-NetTCPConnection -State Established | Where-Object { $_.RemoteAddress -notmatch '^(192\.168\.56\.|10\.0\.2\.|127\.|::1$|fe80::)' }
```

Only loopback, host-only (`192.168.56.*`), and Vagrant's NAT subnet (`10.0.2.*`) should appear. Anything else is a real internet leak — likely a runtime DBeaver update check; see "Disable update checks" below.

---

## Why only four jars

Same set as [docs/07 §5](07-dbeaver-oracle-driver.md). Recap:

| Jar | Removing it triggers |
|---|---|
| `ojdbc8.jar` | `ClassNotFoundException: oracle.jdbc.OracleDriver`. The driver itself is gone. |
| `oraclepki.jar` | `NoClassDefFoundError: oracle/security/o5logon/O5LoginClientHelper`. The Kerberos handler is gone. |
| `osdt_core.jar` | `NoClassDefFoundError: oracle/security/crypto/core/AlgorithmIdentifier` (or similar `crypto.core` / `crypto.asn1` class). ASN.1 encoding fails before any wire bytes are sent. |
| `osdt_cert.jar` | `NoClassDefFoundError: oracle/security/crypto/cert/*`. `oraclepki`'s class init can't complete. |

Anything Oracle also ships but we exclude (`ucp.jar`, `simplefan.jar`, `ons.jar`, `xdb.jar`, `xmlparserv2.jar`, `rsi.jar`, `dms.jar`, `xstreams.jar`, `ojdbc8_g.jar`) is for features DBeaver doesn't use in this flow.

---

## Disable update checks (extra paranoia)

The offline provisioner sets a DBeaver preference disabling startup update checks for the next interactive user (e.g. alice). If you want belt-and-suspenders:

In DBeaver as alice → Window → Preferences:

- **General → Check for updates on startup** → uncheck.
- **Connections → Drivers → Maven** → remove `https://repo1.maven.org/maven2/` from the repository list.
- **General → Network Connections** → set "Active provider" to **Manual** with no HTTP proxy. Combined with no network route, this guarantees DBeaver makes zero outbound calls.

For a stricter posture, disconnect the VM's NAT NIC entirely:

- VirtualBox → wks01 → Settings → Network → Adapter 1 → uncheck **Cable Connected**.
- Leave Adapter 2 (host-only) enabled — that's how it reaches `ad1` and `ora01`.

The connection to Oracle still works because everything Kerberos-flow uses is on the host-only network: TGT request to `ad1.mylab.local`, SQL\*Net to `ora01.mylab.local:1521`.

---

## Rotating the bundle

When ojdbc8 / oraclepki / osdt / DBeaver release new versions, re-run `stage-offline-bundle.ps1` with explicit versions:

```powershell
PS> .\lab\tools\stage-offline-bundle.ps1 -DbeaverVersion 25.4.0 -OjdbcVersion 23.4.0.24.05 -OsdtVersion 21.10.0.0
```

Then re-transfer the changed files (the script is idempotent — already-present files are skipped). New `checksums.txt` will be emitted.

On the target:

```powershell
PS> vagrant provision wks01            # idempotent; re-extracts DBeaver and re-stages jars
```

Or, if you want a clean slate:

```powershell
PS> vagrant destroy wks01 -f
PS> $env:LAB_OFFLINE='1'; $env:AD_ADMIN_PW='...'
PS> vagrant up wks01
```

---

## What this chapter does NOT solve

- **Initial Vagrant box delivery.** `gusztavvargadr/windows-11` is ~10 GB and must be moved over by some mechanism (USB, internal artifact server, network share when the target is briefly online, etc.). The `vagrant box add path\to\box.box` form accepts a pre-downloaded `.box` file.
- **Oracle Database media for ora01.** Oracle 19c install media (`LINUX.X64_193000_db_home.zip`, ~3 GB) must also be transferred separately. Sibling repo's `tableau_ad_oracle/Vagrantfile` expects it on disk before `oracle21c-install.sh` runs.
- **Windows Server 2022 ISO for ad1.** Either pre-image the DC VM on the build side and transfer the .vbox + VDI, or run a Windows Server Vagrant box equivalent (`gusztavvargadr/windows-server-2022-standard`) and run the AD DS install + AD CS install scripts offline.
- **Anti-virus / EDR scans of staged binaries.** If your air-gapped network has its own AV (CrowdStrike, Defender ATP, etc.), each downloaded MSI/JAR/ZIP will be scanned independently. Allow time for those scans before you `vagrant up`.
