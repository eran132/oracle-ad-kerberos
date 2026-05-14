#!/usr/bin/env bash
# ----------------------------------------------------------------------------
# Wrapper for ad-sync-install.sql.
#
# Reads .env (gitignored) for the svc-ora-ldap password and pre-defines the
# &bind_pwd SQL*Plus substitution variable before invoking the installer.
#
# Without this wrapper the installer prompts interactively (HIDE) — that path
# is fine for hands-on installs but bad for automated provisioning.
#
# Run on ora01 as the oracle user. Working directory must be the repo root
# (the script needs to find ../scripts/oracle/ad-sync-install.sql).
# ----------------------------------------------------------------------------
set -euo pipefail

repo_root=$(cd "$(dirname "$0")/../.." && pwd)
installer="$repo_root/scripts/oracle/ad-sync-install.sql"
env_file="$repo_root/.env"

[ -r "$installer" ] || { echo "FATAL: installer not found at $installer" >&2; exit 2; }

if [ -r "$env_file" ]; then
  # shellcheck disable=SC1090
  set -a; . "$env_file"; set +a
else
  echo "WARN: no .env at $env_file — installer will prompt for the password." >&2
fi

if [ -z "${LDAP_BIND_PWD:-}" ]; then
  # Fall back to interactive prompt (the installer's own ACCEPT ... HIDE will fire).
  sqlplus -L / as sysdba @"$installer"
  exit $?
fi

# Pre-define the substitution variable so the installer's ACCEPT is a no-op.
sqlplus -L / as sysdba <<SQL
DEFINE bind_pwd = "${LDAP_BIND_PWD}"
@${installer}
SQL
