# Screenshot capture checklist

The docs in `docs/` use **ASCII mockups** for every DBeaver dialog they reference. Real screenshots are optional but make the runbook friendlier when teammates skim it.

If/when you decide to capture them, save them as `.png` files in this directory using the **exact names** below so the docs can link to them later without renaming. Capture each one **after** the green/success state is reached — most useful as positive references.

| # | File name | What to capture | After completing |
|---|---|---|---|
| 01 | `01-driver-libraries.png` | DBeaver → Database menu → Driver Manager → Oracle → Edit Driver → **Libraries** tab. All four jars listed, Class Name = `oracle.jdbc.OracleDriver`. | [docs/07 section 3](../docs/07-dbeaver-oracle-driver.md#3-register-the-jars-in-dbeavers-driver-definition) |
| 02 | `02-connection-main-tab.png` | New Connection → Oracle → **Main** tab. Host=`ora01.mylab.local`, Port=`1521`, Database=`orclpdb1`, Service Name radio selected, Authentication=`Database Native`, **Username and Password blank**. | [docs/08 section 2](../docs/08-dbeaver-connection.md#2-new-connection--main-tab) |
| 03 | `03-driver-properties-tab.png` | Same dialog → **Driver properties** tab showing `oracle.net.authentication_services=(KERBEROS5)` and `oracle.net.kerberos5_mutual_authentication=true`. | [docs/08 section 3](../docs/08-dbeaver-connection.md#3-driver-properties-tab) |
| 04 | `04-test-connection-success.png` | The green **Connection Test Succeeded** dialog with the Oracle version line visible. | [docs/08 section 4](../docs/08-dbeaver-connection.md#4-test-the-connection) |
| 05 | `05-select-user-result.png` | DBeaver SQL editor showing `SELECT USER, SYS_CONTEXT('USERENV','AUTHENTICATION_METHOD') FROM DUAL;` with result row `ALICE@MYLAB.LOCAL | KERBEROS`. | [docs/09 section 6](../docs/09-verification-end-to-end.md#6-dbeaver-confirm-the-identity) |
| 06 | `06-klist-after-kvno.png` *(optional)* | PowerShell window with `klist` output showing both `krbtgt/MYLAB.LOCAL` and `oracle/ora01.mylab.local` entries after `kvno`. | [docs/09 section 4](../docs/09-verification-end-to-end.md#4-request-the-oracle-service-ticket) |
| 07 | `07-precheck-summary.png` *(optional)* | PowerShell window with `Invoke-DBeaverPrecheck.ps1` "All checks passed" summary table. | [docs/09 section 1](../docs/09-verification-end-to-end.md#1-non-interactive-preflight) |

## Capture tips

- Window-only screenshots (`Alt+PrtScn`) keep file size small and avoid leaking other desktop content. Don't use full-screen captures.
- Sanitize: blur or crop any visible domain credentials, principal passwords, host IPs you don't want to publish.
- DBeaver supports a dark theme — use whichever you prefer, but be consistent across all seven so the runbook doesn't look stitched together.
- PNG, not JPG — text in screenshots stays sharp.

## When ASCII mockups stay

Even after you capture real screenshots, **leave the ASCII mockups in the docs**. They are searchable (grep-friendly), survive image-broken links, and serve as accessible alt-text. Real screenshots augment them; they don't replace them.
