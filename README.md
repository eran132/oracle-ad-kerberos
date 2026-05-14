# oracle_Ad_kerberos

End-to-end documentation for **Active Directory user → Oracle 19c → DBeaver on Windows** authentication using Kerberos (keytab + SPN, no password prompt at connect time).

## Project goal

Prove and document that an AD user can `kinit` on a Windows host, open DBeaver, hit `ORCLPDB1` on a Kerberos-enabled Oracle 19c server, and run queries as themselves — no Oracle password configured anywhere on the client. This repo is both the runbook and a set of verification scripts that confirm each link in the chain.

> Lab is Oracle 19c; the same setup works identically on 21c/23ai because Kerberos integration is a SQL\*Net feature, not version-specific.

## Lab topology

```
                       (vboxnet0 host-only 192.168.56.0/24)
                       
   +-------------------+        Kerberos        +-----------------------+
   | Windows 11 host   |  <------------------>  | ad1.mylab.local       |
   | DBeaver + MIT KfW |   88/tcp 88/udp 464    | Win Server 2022 DC    |
   | 192.168.56.1      |   636 LDAPS  88/464    | 192.168.56.10         |
   |  + mylab-root-ca  |     (PKI: AD CS)       |  + mylab-root-ca (CA) |
   +---------+---------+                        +-----------+-----------+
             |                                              ^
             |   SQL*Net + GSSAPI (1521/tcp)                |  AS-REQ / TGS-REQ
             v                                              |
   +-------------------+   service ticket for oracle/...    |
   | ora01.mylab.local |  <---------------------------------+
   | RHEL 9 + Oracle19c|
   | 192.168.56.20     |
   | listener 1521     |
   | PDB orclpdb1      |
   | /etc/oracle/keytabs/ora01.keytab
   +-------------------+
```

- Realm: `MYLAB.LOCAL` · Oracle SPN: `oracle/ora01.mylab.local@MYLAB.LOCAL` · AD svc account: `svc-ora01`
- Sample AD users: `alice`, `bob`, `carol`

## Reading order

1. [docs/01-architecture.md](docs/01-architecture.md) — ticket flow, who talks to whom
2. [docs/02-prereqs-lab-bringup.md](docs/02-prereqs-lab-bringup.md) — VMs, network, what must be running
3. [docs/03-ad-and-spn-setup.md](docs/03-ad-and-spn-setup.md) — `svc-ora01`, SPN, keytab
4. [docs/04-oracle-server-kerberos.md](docs/04-oracle-server-kerberos.md) — `sqlnet.ora`, externally identified users
5. [docs/05-windows-client-mit-krb.md](docs/05-windows-client-mit-krb.md) — MIT Kerberos for Windows + `krb5.ini`
6. [docs/06-windows-lsa-and-ccache.md](docs/06-windows-lsa-and-ccache.md) — `allowtgtsessionkey`, LSA vs file ccache
7. [docs/07-dbeaver-oracle-driver.md](docs/07-dbeaver-oracle-driver.md) — ojdbc8 + companion jars
8. [docs/08-dbeaver-connection.md](docs/08-dbeaver-connection.md) — connection properties + JVM args
9. [docs/09-verification-end-to-end.md](docs/09-verification-end-to-end.md) — `kinit`→`klist`→`kvno`→DBeaver
10. [docs/10-operations-rotation.md](docs/10-operations-rotation.md) — keytab rotation, audit checklist
11. [docs/11-ldaps-cert-trust.md](docs/11-ldaps-cert-trust.md) — LDAPS, AD CS, and the lab Root CA trust chain
12. [docs/12-install-record.md](docs/12-install-record.md) — exact methods, URLs, and versions for every binary, jar, and cert installed during the 2026-05-13 build
13. [docs/13-domain-joined-workstation.md](docs/13-domain-joined-workstation.md) — the no-`kinit` path: a domain-joined `wks01` Windows VM (instead of your laptop), built by [lab/](lab/)
14. [docs/14-air-gapped.md](docs/14-air-gapped.md) — offline / air-gapped provisioning: bundle the ~140 MB of downloads on an online build PC, sneakernet to the isolated network, `LAB_OFFLINE=1 vagrant up wks01`
15. [docs/15-questions-and-answers.md](docs/15-questions-and-answers.md) — FAQ: do I have to `kinit` every time? where do I run X? why 4 jars? why does ad1 keep powering off?

Side material: [troubleshooting.md](troubleshooting.md) · [screenshots/](screenshots/) · [config/windows/](config/windows/) · [config/windows/trust/](config/windows/trust/) · [scripts/windows/](scripts/windows/) · [lab/](lab/) (workstation VM)

## What this repo adds vs. the sibling lab

The companion lab at `..\tableau_ad_oracle\` provisions the AD and Oracle server side (Vagrant, AD account/SPN/keytab creation, `sqlnet.ora`, Linux verification). **This repo does not duplicate any of that.** It adds the **Windows client + DBeaver** half that the sibling repo does not cover, and a runbook that walks the full path top-to-bottom for someone whose ultimate goal is "DBeaver, hit Enter, query as myself."

### Link-map to the sibling lab

| Purpose | Sibling-repo file |
|---|---|
| Bring up `ad1` + `ora01` VMs | [..\tableau_ad_oracle\Vagrantfile](../tableau_ad_oracle/Vagrantfile) |
| Server-side `krb5.conf` template | [..\tableau_ad_oracle\config\krb5.conf.example](../tableau_ad_oracle/config/krb5.conf.example) |
| Oracle `sqlnet.ora` template | [..\tableau_ad_oracle\config\oracle-sqlnet.ora.example](../tableau_ad_oracle/config/oracle-sqlnet.ora.example) |
| Oracle `tnsnames.ora` template | [..\tableau_ad_oracle\config\oracle-tnsnames.ora.example](../tableau_ad_oracle/config/oracle-tnsnames.ora.example) |
| Create `svc-ora01` + SPN on AD | [..\tableau_ad_oracle\scripts\ad-create-lab-accounts.ps1](../tableau_ad_oracle/scripts/ad-create-lab-accounts.ps1) |
| Generate Oracle keytab (`ktpass`) | [..\tableau_ad_oracle\scripts\ktpass-keytabs.ps1](../tableau_ad_oracle/scripts/ktpass-keytabs.ps1) |
| Join Oracle host to AD | [..\tableau_ad_oracle\scripts\realm-join.sh](../tableau_ad_oracle/scripts/realm-join.sh) |
| Apply Kerberos to Oracle 21c | [..\tableau_ad_oracle\scripts\oracle21c-kerberos.sh](../tableau_ad_oracle/scripts/oracle21c-kerberos.sh) |
| Validate keytab on the server | [..\tableau_ad_oracle\scripts\keytab-check.sh](../tableau_ad_oracle/scripts/keytab-check.sh) |
| Validate user→Oracle from Linux | [..\tableau_ad_oracle\scripts\user-oracle-ticket-check.sh](../tableau_ad_oracle/scripts/user-oracle-ticket-check.sh) |
| Lab Root CA cert (DER + PEM) | [config/windows/trust/mylab-root-ca.cer](config/windows/trust/mylab-root-ca.cer) · [.pem](config/windows/trust/mylab-root-ca.pem) — exported from ad1 (this repo holds the only canonical copy) |

## Quickstart (impatient path)

Once the lab VMs are up and the sibling-repo scripts have run on the server side:

```powershell
# 1. Preflight — DNS, ports, clock skew, krb5.ini, AD SPN, AES enctype
PS> .\scripts\windows\Invoke-DBeaverPrecheck.ps1

# 2. Get a ticket as the AD user (no Oracle password)
PS> kinit alice@MYLAB.LOCAL
PS> klist                          # expect krbtgt + maybe oracle/... entries
PS> kvno oracle/ora01.mylab.local@MYLAB.LOCAL

# 3. Open DBeaver -> ORCLPDB1 connection (username blank) -> Test Connection
# 4. SQL editor:  SELECT USER FROM DUAL;   -> ALICE@MYLAB.LOCAL
```

If any step fails, jump to [troubleshooting.md](troubleshooting.md) — every error mode there is anchor-linked from [docs/09-verification-end-to-end.md](docs/09-verification-end-to-end.md).

## Glossary

| Term | Meaning |
|---|---|
| **SPN** | Service Principal Name — string like `oracle/ora01.mylab.local@MYLAB.LOCAL` that identifies a Kerberos-protected service. Registered in AD on the service account. |
| **KDC** | Key Distribution Center — the AD domain controller (`ad1.mylab.local`) when AD is the realm. |
| **TGT** | Ticket Granting Ticket — your "passport" obtained at `kinit`; valid ~10 h. Used to request service tickets. |
| **ST** | Service Ticket — short-lived token for a specific SPN; what DBeaver actually presents to Oracle. |
| **ccache** | Credential cache — where your TGT and STs live on the client. On Windows: LSA cache (default) or a file (`KRB5CCNAME=FILE:...`). |
| **kvno** | Key Version Number — increments each time the service account password rotates; keytab and AD must agree or you get `KRB_AP_ERR_MODIFIED`. |
| **Keytab** | A file containing the service's long-term key, used so the service can decrypt incoming tickets without an interactive password. Generated by `ktpass` from the AD account. |
| **Principal** | Canonical Kerberos identity, e.g. `alice@MYLAB.LOCAL` (user principal) or `oracle/ora01.mylab.local@MYLAB.LOCAL` (service principal). |

## Verifying the documentation itself

The runbook is "done" when a fresh teammate, given only this repo plus access to the running VirtualBox lab, can complete the four steps under **Quickstart** above without consulting anything other than `troubleshooting.md`. See [docs/09-verification-end-to-end.md](docs/09-verification-end-to-end.md) for the formal walkthrough.

---

## Notes for cloners / forkers

**Sibling-repo dependency (server side).** Several chapters reference a sibling `tableau_ad_oracle` repo at `..\tableau_ad_oracle\` that builds the AD + Oracle server-side lab (Vagrantfile, AD account/SPN scripts, `ktpass`, `sqlnet.ora`, realm-join). That repo is **not** included here; this one focuses on the Kerberos-auth + DBeaver client side. If you don't have an equivalent backend, the runbook still tells you exactly what needs to exist on the AD DC and the Oracle host — you can substitute any tooling that produces the same end state (`svc-ora01` account with SPN `oracle/<host>.<realm>`, AD CS-issued DC cert, `sqlnet.ora` with `SQLNET.AUTHENTICATION_SERVICES=(KERBEROS5)`, externally-identified users in the DB).

**Lab-specific values.** The lab uses `MYLAB.LOCAL` / `mylab.local`, `ad1.mylab.local`, `ora01.mylab.local`, `ORCLPDB1`, and test users `alice` / `bob` / `carol`. To repurpose for your environment, search-replace these throughout `docs/`, `config/`, `lab/`, and `troubleshooting.md`.

**What's in the repo vs. gitignored.** Tracked: docs, scripts, config templates, the lab Root CA cert (public key only — its private key lives in AD CS on the DC, not in the repo). Gitignored: `.claude/`, `.vagrant/`, `lab/bundle/*` (large reproducible binaries — re-fetch with `lab/tools/stage-offline-bundle.ps1`). See `.gitignore` for the full list.

**No secrets in the tree.** Passwords are only ever read at runtime from `$env:AD_ADMIN_PW` (and similar). The provisioners refuse to start without them.

## License

[MIT](LICENSE).
