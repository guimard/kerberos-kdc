#!/usr/bin/env bash
#
# Copyright (C) 2026 LINAGORA <https://linagora.com>
# Author: Xavier Guimard <xguimard@linagora.com>
# SPDX-License-Identifier: AGPL-3.0-or-later
#
# This program is free software: you can redistribute it and/or modify it under
# the terms of the GNU Affero General Public License as published by the Free
# Software Foundation, either version 3 of the License, or (at your option) any
# later version. It is distributed WITHOUT ANY WARRANTY; see the GNU Affero
# General Public License <https://www.gnu.org/licenses/> for details.
#
# Entrypoint for pure-kdc-ldap: a dedicated OpenLDAP backend for the Kerberos
# KDC. On first boot it (re)initializes slapd with the requested suffix, loads
# the MIT Kerberos cn=config schema, creates the two service accounts the KDC
# binds as, and applies ACLs. Then it runs slapd in the foreground.
#
# The realm container (krbContainer) and the principals themselves are created
# by the KDC side (kdb5_ldap_util create / kadmin), not here.
#
set -euo pipefail

# --------------------------------------------------------------------------
# Configuration (env)
# --------------------------------------------------------------------------
LDAP_DOMAIN="${LDAP_DOMAIN:-example.com}"
LDAP_ORGANISATION="${LDAP_ORGANISATION:-Example}"
: "${LDAP_ADMIN_PASSWORD:?LDAP_ADMIN_PASSWORD is required}"

# Suffix is derived from the domain (dc components).
LDAP_SUFFIX="dc=$(echo "$LDAP_DOMAIN" | sed 's/\./,dc=/g')"
ADMIN_DN="cn=admin,${LDAP_SUFFIX}"

# Where the KDC will create its realm container (used for ACL scoping/docs).
KRB_CONTAINER_DN="${KRB_CONTAINER_DN:-cn=krbContainer,${LDAP_SUFFIX}}"

# Service accounts the KDC binds as. Must be cn=<x>,ou=services,<suffix>.
LDAP_KDC_DN="${LDAP_KDC_DN:-cn=kdc-service,ou=services,${LDAP_SUFFIX}}"
: "${LDAP_KDC_PASSWORD:?LDAP_KDC_PASSWORD is required}"
LDAP_KADMIN_DN="${LDAP_KADMIN_DN:-cn=kadmin-service,ou=services,${LDAP_SUFFIX}}"
: "${LDAP_KADMIN_PASSWORD:?LDAP_KADMIN_PASSWORD is required}"

SCHEMA="/etc/ldap/schema/kerberos.openldap.ldif"
MARKER="/var/lib/ldap/.pure-kdc-ldap-initialized"
SLAPD_URLS="${SLAPD_URLS:-ldap:/// ldapi:///}"

log() { echo "[pure-kdc-ldap] $*" >&2; }

rdn_value() { echo "$1" | sed -E 's/^[a-zA-Z]+=([^,]+),.*/\1/'; }

ensure_runtime_dirs() {
  install -d -o openldap -g openldap /run/slapd
}

wait_ldapi() {
  local i
  for i in $(seq 1 50); do
    ldapsearch -Q -Y EXTERNAL -H ldapi:/// -b "" -s base >/dev/null 2>&1 && return 0
    sleep 0.2
  done
  log "ERROR: slapd (ldapi) did not become ready"
  return 1
}

stop_slapd() {
  pkill -TERM slapd 2>/dev/null || true
  local i
  for i in $(seq 1 25); do pgrep -x slapd >/dev/null || return 0; sleep 0.2; done
}

# --------------------------------------------------------------------------
# First-boot initialization
# --------------------------------------------------------------------------
reconfigure_slapd() {
  log "Initializing slapd config for suffix ${LDAP_SUFFIX}"
  stop_slapd
  rm -rf /etc/ldap/slapd.d/* /var/lib/ldap/*
  debconf-set-selections <<EOF
slapd slapd/no_configuration boolean false
slapd slapd/domain string ${LDAP_DOMAIN}
slapd shared/organization string ${LDAP_ORGANISATION}
slapd slapd/backend string MDB
slapd slapd/purge_database boolean true
slapd slapd/move_old_database boolean true
slapd slapd/allow_ldap_v2 boolean false
slapd slapd/password1 password ${LDAP_ADMIN_PASSWORD}
slapd slapd/password2 password ${LDAP_ADMIN_PASSWORD}
EOF
  dpkg-reconfigure -f noninteractive slapd >/dev/null 2>&1
  stop_slapd   # postinst may have started one via invoke-rc.d
}

load_schema() {
  log "Loading Kerberos schema (cn=config) from ${SCHEMA}"
  ldapadd -Q -Y EXTERNAL -H ldapi:/// -f "$SCHEMA" >/dev/null
}

load_entries() {
  log "Creating ou=services + service accounts"
  local kdc_hash kadmin_hash
  kdc_hash="$(slappasswd -s "$LDAP_KDC_PASSWORD")"
  kadmin_hash="$(slappasswd -s "$LDAP_KADMIN_PASSWORD")"

  ldapadd -x -H ldapi:/// -D "$ADMIN_DN" -w "$LDAP_ADMIN_PASSWORD" >/dev/null <<EOF
dn: ou=services,${LDAP_SUFFIX}
objectClass: organizationalUnit
ou: services

dn: ${LDAP_KDC_DN}
objectClass: organizationalRole
objectClass: simpleSecurityObject
cn: $(rdn_value "$LDAP_KDC_DN")
description: KDC bind account (read-only on the Kerberos subtree)
userPassword: ${kdc_hash}

dn: ${LDAP_KADMIN_DN}
objectClass: organizationalRole
objectClass: simpleSecurityObject
cn: $(rdn_value "$LDAP_KADMIN_DN")
description: kadmind bind account (read-write on the Kerberos subtree)
userPassword: ${kadmin_hash}
EOF

  log "Applying ACLs on the data backend"
  # NB: prototype-grade. kadmind needs write across the suffix so
  # kdb5_ldap_util can create the realm container; kdc only reads.
  ldapmodify -Q -Y EXTERNAL -H ldapi:/// >/dev/null <<EOF
dn: olcDatabase={1}mdb,cn=config
changetype: modify
replace: olcAccess
olcAccess: {0}to attrs=userPassword
  by self write
  by dn.exact="${ADMIN_DN}" manage
  by dn.exact="${LDAP_KADMIN_DN}" write
  by anonymous auth
  by * none
olcAccess: {1}to *
  by dn.exact="${ADMIN_DN}" manage
  by dn.exact="${LDAP_KADMIN_DN}" write
  by dn.exact="${LDAP_KDC_DN}" read
  by * none
EOF
}

initialize() {
  reconfigure_slapd
  ensure_runtime_dirs
  slapd -h "$SLAPD_URLS" -u openldap -g openldap   # daemonizes
  wait_ldapi
  load_schema
  load_entries
  stop_slapd
  touch "$MARKER"
  log "Initialization complete (suffix=${LDAP_SUFFIX}, krbContainer target=${KRB_CONTAINER_DN})"
}

# --------------------------------------------------------------------------
# Main
# --------------------------------------------------------------------------
main() {
  case "${1:-slapd}" in
    slapd)
      ensure_runtime_dirs
      [ -f "$MARKER" ] || initialize
      log "Starting slapd (foreground) for ${LDAP_SUFFIX}"
      exec slapd -h "$SLAPD_URLS" -u openldap -g openldap -d "${SLAPD_LOG_LEVEL:-256}"
      ;;
    *)
      exec "$@"
      ;;
  esac
}

main "$@"
