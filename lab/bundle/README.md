# `lab/bundle/` — offline-install staging area

This directory is **gitignored** and holds the binary blobs needed to provision `wks01` (and optionally a non-domain client) **without any outbound network access** from the target environment.

Populate it from an internet-connected PC by running:

```powershell
PS> .\tools\stage-offline-bundle.ps1                  # baseline bundle
PS> .\tools\stage-offline-bundle.ps1 -IncludeMitKfw   # also grab MIT KfW MSI
```

The script writes files here, computes SHA-256 checksums, and emits `checksums.txt` so the offline provisioner can verify integrity.

## Expected layout

```
lab/bundle/
├── dbeaver-portable.zip          (~123 MB, DBeaver Community portable)
├── ojdbc8.jar                    (Oracle JDBC thin driver)
├── oraclepki.jar                 (O5Logon / Kerberos token handler)
├── osdt_core.jar                 (Oracle Security Developer Tools - core)
├── osdt_cert.jar                 (Oracle Security Developer Tools - cert)
├── mylab-root-ca.cer             (lab Root CA, DER)
├── mylab-root-ca.pem             (same, PEM)
├── kfw-4.1-amd64.msi             (optional, only with -IncludeMitKfw)
├── corp-proxy-CAs/
│   ├── bluecoat-cloud-services-root-ca.crt   (if your network has one)
│   └── symantec-enterprise-mobile-root.crt
└── checksums.txt                 (SHA-256 manifest)
```

Total size: **~140 MB** without MIT KfW, **~151 MB** with it.

## After the bundle lands on your air-gapped PC

```powershell
PS> cd lab
PS> $env:LAB_OFFLINE = '1'
PS> $env:AD_ADMIN_PW = '<the Administrator password>'
PS> vagrant up wks01
```

The Vagrantfile detects `LAB_OFFLINE=1`, uploads everything in `lab/bundle/` to `C:\Windows\Temp\bundle\` inside the guest, and uses [../provision/02-install-dbeaver-offline.ps1](../provision/02-install-dbeaver-offline.ps1) (which reads from that path) instead of the network-bound default.

See [../../docs/14-air-gapped.md](../../docs/14-air-gapped.md) for the full workflow.
