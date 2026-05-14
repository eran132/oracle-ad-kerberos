# Linux-side config — pointers, not copies

This directory exists so that the `config/` layout mirrors `scripts/` and is symmetric for readers, but **all server-side config templates already live in the sibling lab**. Copying them here would create two sources of truth that drift.

If you need the Linux Kerberos / Oracle config templates, edit them in the sibling repo and re-run the appropriate provisioning script there.

| What you need | Where it lives |
|---|---|
| `krb5.conf` for the Oracle host | [../../../tableau_ad_oracle/config/krb5.conf.example](../../../tableau_ad_oracle/config/krb5.conf.example) |
| `sqlnet.ora` with `KERBEROS5` + keytab path | [../../../tableau_ad_oracle/config/oracle-sqlnet.ora.example](../../../tableau_ad_oracle/config/oracle-sqlnet.ora.example) |
| `tnsnames.ora` for `ORCLPDB1` | [../../../tableau_ad_oracle/config/oracle-tnsnames.ora.example](../../../tableau_ad_oracle/config/oracle-tnsnames.ora.example) |
| Apply `sqlnet.ora` + create externally-identified users | [../../../tableau_ad_oracle/scripts/oracle21c-kerberos.sh](../../../tableau_ad_oracle/scripts/oracle21c-kerberos.sh) |
| Join Oracle host to AD (sssd + realmd) | [../../../tableau_ad_oracle/scripts/realm-join.sh](../../../tableau_ad_oracle/scripts/realm-join.sh) |
| Generate keytab on the DC | [../../../tableau_ad_oracle/scripts/ktpass-keytabs.ps1](../../../tableau_ad_oracle/scripts/ktpass-keytabs.ps1) |
| Validate keytab on the Oracle host | [../../../tableau_ad_oracle/scripts/keytab-check.sh](../../../tableau_ad_oracle/scripts/keytab-check.sh) |
| Validate AD user → Oracle from Linux | [../../../tableau_ad_oracle/scripts/user-oracle-ticket-check.sh](../../../tableau_ad_oracle/scripts/user-oracle-ticket-check.sh) |

For Windows-side configuration (krb5.ini, dbeaver-jvm-args, allowtgtsessionkey.reg), see [../windows/](../windows/).
