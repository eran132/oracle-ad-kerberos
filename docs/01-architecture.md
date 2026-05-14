# 01 · Architecture and Kerberos ticket flow

The point of this chapter is to give a mental model that holds up when something breaks. If you only remember one diagram from this repo, it should be the one below.

---

## Actors

| Actor | Role | Identity |
|---|---|---|
| **AD user** | The human who wants to query Oracle. | `alice@MYLAB.LOCAL` (user principal) |
| **Windows host** | The desktop running DBeaver + MIT Kerberos for Windows. | *(not a Kerberos principal; just a workstation)* |
| **DBeaver / JVM** | The application that calls Oracle JDBC. Reads tickets from the file ccache. | *(no principal of its own; runs as `alice` for Kerberos purposes)* |
| **KDC** | The Active Directory domain controller. Issues TGTs and STs. | `ad1.mylab.local`, realm `MYLAB.LOCAL` |
| **Oracle service** | The DB server that authenticates clients via Kerberos. | `oracle/ora01.mylab.local@MYLAB.LOCAL` (service principal) |
| **AD service account** | Holds the SPN and the long-term key for the service principal. | `svc-ora01` (AD sAMAccountName) |
| **Keytab** | File on the Oracle host containing the long-term key. | `/etc/oracle/keytabs/ora01.keytab` |

## The flow

```
Step 1: kinit (Windows host)
  alice ──── AS-REQ (cleartext + pre-auth ts) ────▶ KDC
        ◀──── AS-REP (TGT for alice, encrypted with alice's key) ────
  Result: TGT cached at $env:KRB5CCNAME on the Windows host.

Step 2: kvno or DBeaver Test Connection
  alice's JVM ──── TGS-REQ ("I have TGT, give me ticket for oracle/...") ────▶ KDC
              ◀──── TGS-REP (ST for oracle/..., encrypted with svc-ora01's key) ────
  Result: Service ticket cached alongside the TGT.

Step 3: DBeaver opens TCP 1521 to ora01
  JVM (ojdbc) ──── SQL*Net handshake ────▶ Oracle listener
  JVM         ──── AP-REQ (presents ST + authenticator) ────▶ Oracle
  Oracle reads /etc/oracle/keytabs/ora01.keytab,
  uses the same key to decrypt ST. If it succeeds, identity
  inside the ST is `alice@MYLAB.LOCAL`.
  Oracle looks up CREATE USER "ALICE@MYLAB.LOCAL" IDENTIFIED EXTERNALLY,
  finds it, grants the session.

Step 4: Queries
  Oracle treats the session as user ALICE@MYLAB.LOCAL.
  SELECT USER FROM DUAL → 'ALICE@MYLAB.LOCAL'
```

## Why each piece exists

| Piece | Without it… |
|---|---|
| **TGT** | Every service connection would require the user's password again. The TGT is the "logged-in" credential. |
| **SPN** (`oracle/ora01.mylab.local`) | The KDC wouldn't know what key to use when encrypting the service ticket for Oracle. |
| **Keytab** on the Oracle host | Oracle couldn't decrypt the service ticket (it doesn't know the password of `svc-ora01`). |
| **`svc-ora01` AD account** | There would be no entry in AD to hold the SPN and its key. The KDC needs *some* principal record. |
| **Externally identified user** (`CREATE USER "ALICE@MYLAB.LOCAL" IDENTIFIED EXTERNALLY`) | Oracle would refuse the session: ticket valid, but no matching user. |
| **`OS_AUTHENT_PREFIX=''`** | Oracle would prefix the external name with `OPS$` (the default), so the user would have to be `OPS$ALICE@MYLAB.LOCAL`. |
| **MIT KfW on Windows** | No `kinit`/`klist`/`kvno` CLI; you'd have to rely on Windows native SSPI which only works on domain-joined hosts. |
| **`KRB5CCNAME` env var** | JGSS in DBeaver's JVM and MIT CLI tools would use **different** caches; you'd `kinit` and DBeaver wouldn't see the ticket. |

## Where things tend to break

Map of failure modes to the protocol step where they manifest:

| Step | What can go wrong | Anchor |
|---|---|---|
| 1. AS-REQ/AS-REP | Wrong password, clock skew, realm casing, DNS | [troubleshooting.md#clock-skew](../troubleshooting.md#clock-skew), [#dns-resolution](../troubleshooting.md#dns-resolution) |
| 2. TGS-REQ/TGS-REP | SPN missing, duplicate SPN, enctype mismatch | [#kdc-err-s-principal-unknown](../troubleshooting.md#kdc-err-s-principal-unknown), [#enctype-mismatch](../troubleshooting.md#enctype-mismatch) |
| 3a. SQL*Net handshake | Network or listener; not Kerberos's fault | listener / firewall |
| 3b. AP-REQ decryption | Keytab/AD password drift, wrong enctype in keytab | [#krb-ap-err-modified](../troubleshooting.md#krb-ap-err-modified) |
| 3c. Oracle user lookup | External user not created / wrong case / `OS_AUTHENT_PREFIX` wrong | [docs/04](04-oracle-server-kerberos.md) |
| JVM side of step 3 | `KRB5CCNAME` not in DBeaver env, companion jars missing, `useSubjectCredsOnly` true | [#ora-12638](../troubleshooting.md#ora-12638), [#jdbc-noclassdef-o5login](../troubleshooting.md#jdbc-noclassdef-o5login) |

## What this chapter intentionally skips

- Constrained delegation (S4U2Proxy). The sibling lab sets up `svc-tab-deleg` for Tableau-style impersonation; we don't need it because DBeaver acts directly as the user.
- Cross-realm trust. The whole lab is a single realm `MYLAB.LOCAL`.
- AES vs RC4 negotiation in detail. We force AES on both sides; if you must support RC4, see Microsoft KB about `msDS-SupportedEncryptionTypes`.
- PKINIT (smartcard logon). Out of scope.

Next: [02 · Lab prereqs and bring-up](02-prereqs-lab-bringup.md).
