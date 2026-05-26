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
# Entrypoint for the pure-kdc image.
#
# Renders /etc/krb5.conf and /etc/krb5kdc/kdc.conf from environment variables,
# stashes the LDAP service-account password(s) and the KDB master key, then
# runs krb5kdc + kadmind in the foreground.
#
# The Kerberos database itself lives in the *external* OpenLDAP server; this
# container is stateless except for the stash files under /etc/krb5kdc.
#
set -euo pipefail

log() { echo "[pure-kdc] $*" >&2; }

DBMODULE="openldap_ldapconf"
KDC_DIR="/etc/krb5kdc"
KDC_CONF="${KDC_DIR}/kdc.conf"
KRB5_CONF="/etc/krb5.conf"

# --------------------------------------------------------------------------
# Validate required vars, apply defaults and derive paths.
# Only called for the service subcommands (run/kdc/kadmin) so that one-off
# passthrough commands (e.g. `docker run pure-kdc zcat .../kerberos.ldif.gz`,
# `docker exec ... kadmin.local`) do not need the full environment.
# --------------------------------------------------------------------------
load_config() {
  # ---- Required ----
  : "${KRB5_REALM:?KRB5_REALM is required (e.g. EXAMPLE.COM)}"
  : "${LDAP_SERVERS:?LDAP_SERVERS is required (e.g. ldaps://ldap.example.com)}"
  : "${LDAP_KERBEROS_CONTAINER_DN:?LDAP_KERBEROS_CONTAINER_DN is required (e.g. cn=krbContainer,dc=example,dc=com)}"
  : "${LDAP_KDC_DN:?LDAP_KDC_DN is required (bind DN used by krb5kdc, read-only)}"
  : "${LDAP_KDC_PASSWORD:?LDAP_KDC_PASSWORD is required}"
  : "${LDAP_KADMIN_DN:?LDAP_KADMIN_DN is required (bind DN used by kadmind, read-write)}"
  : "${LDAP_KADMIN_PASSWORD:?LDAP_KADMIN_PASSWORD is required}"
  : "${KRB5_MASTER_PASSWORD:?KRB5_MASTER_PASSWORD is required (KDB master key)}"

  # ---- Optional (with defaults) ----
  # FQDN advertised to clients in krb5.conf. Defaults to the container hostname.
  KRB5_KDC_HOSTNAME="${KRB5_KDC_HOSTNAME:-$(hostname -f 2>/dev/null || hostname)}"
  # DNS domain for the [domain_realm] mapping. Defaults to lowercase realm.
  KRB5_DOMAIN="${KRB5_DOMAIN:-$(echo "$KRB5_REALM" | tr '[:upper:]' '[:lower:]')}"

  KRB5_KDC_PORTS="${KRB5_KDC_PORTS:-88}"
  KRB5_KADMIN_PORT="${KRB5_KADMIN_PORT:-749}"
  KRB5_KPASSWD_PORT="${KRB5_KPASSWD_PORT:-464}"

  KRB5_MAX_LIFE="${KRB5_MAX_LIFE:-24h 0m 0s}"
  KRB5_MAX_RENEWABLE_LIFE="${KRB5_MAX_RENEWABLE_LIFE:-7d 0h 0m 0s}"
  KRB5_SUPPORTED_ENCTYPES="${KRB5_SUPPORTED_ENCTYPES:-aes256-cts-hmac-sha1-96:normal aes128-cts-hmac-sha1-96:normal}"

  LDAP_CONNS_PER_SERVER="${LDAP_CONNS_PER_SERVER:-5}"
  DNS_LOOKUP_KDC="${DNS_LOOKUP_KDC:-false}"
  DNS_LOOKUP_REALM="${DNS_LOOKUP_REALM:-false}"

  # Set KRB5_CREATE_REALM=true on first boot to provision the realm container
  # in LDAP. Requires an admin bind able to write under the container DN.
  KRB5_CREATE_REALM="${KRB5_CREATE_REALM:-false}"
  LDAP_ADMIN_DN="${LDAP_ADMIN_DN:-}"
  LDAP_ADMIN_PASSWORD="${LDAP_ADMIN_PASSWORD:-}"
  # Subtree(s) under which principals live; defaults to the container base DN.
  LDAP_SUBTREES="${LDAP_SUBTREES:-}"

  # ---- Derived paths ----
  STASH_MASTER="${KDC_DIR}/.k5.${KRB5_REALM}"
  SERVICE_KEYFILE="${KDC_DIR}/service.keyfile"

  mkdir -p "$KDC_DIR"
}

# --------------------------------------------------------------------------
# Render /etc/krb5.conf
# --------------------------------------------------------------------------
render_krb5_conf() {
  log "Rendering ${KRB5_CONF}"
  cat > "$KRB5_CONF" <<EOF
[libdefaults]
    default_realm = ${KRB5_REALM}
    dns_lookup_realm = ${DNS_LOOKUP_REALM}
    dns_lookup_kdc = ${DNS_LOOKUP_KDC}
    rdns = false
    forwardable = true
    default_tkt_enctypes = ${KRB5_SUPPORTED_ENCTYPES//:normal/}
    default_tgs_enctypes = ${KRB5_SUPPORTED_ENCTYPES//:normal/}

[realms]
    ${KRB5_REALM} = {
        kdc = ${KRB5_KDC_HOSTNAME}:${KRB5_KDC_PORTS%% *}
        admin_server = ${KRB5_KDC_HOSTNAME}:${KRB5_KADMIN_PORT}
        kpasswd_server = ${KRB5_KDC_HOSTNAME}:${KRB5_KPASSWD_PORT}
        default_domain = ${KRB5_DOMAIN}
    }

[domain_realm]
    .${KRB5_DOMAIN} = ${KRB5_REALM}
    ${KRB5_DOMAIN} = ${KRB5_REALM}

[logging]
    kdc = STDERR
    admin_server = STDERR
    default = STDERR
EOF
}

# --------------------------------------------------------------------------
# Render /etc/krb5kdc/kdc.conf
# --------------------------------------------------------------------------
render_kdc_conf() {
  log "Rendering ${KDC_CONF}"
  cat > "$KDC_CONF" <<EOF
[kdcdefaults]
    kdc_ports = ${KRB5_KDC_PORTS}
    kdc_tcp_ports = ${KRB5_KDC_PORTS}

[realms]
    ${KRB5_REALM} = {
        database_module = ${DBMODULE}
        key_stash_file = ${STASH_MASTER}
        kadmind_port = ${KRB5_KADMIN_PORT}
        kpasswd_port = ${KRB5_KPASSWD_PORT}
        max_life = ${KRB5_MAX_LIFE}
        max_renewable_life = ${KRB5_MAX_RENEWABLE_LIFE}
        supported_enctypes = ${KRB5_SUPPORTED_ENCTYPES}
    }

[dbmodules]
    ${DBMODULE} = {
        db_library = kldap
        ldap_kerberos_container_dn = ${LDAP_KERBEROS_CONTAINER_DN}
        ldap_kdc_dn = "${LDAP_KDC_DN}"
        ldap_kadmind_dn = "${LDAP_KADMIN_DN}"
        ldap_service_password_file = ${SERVICE_KEYFILE}
        ldap_servers = ${LDAP_SERVERS}
        ldap_conns_per_server = ${LDAP_CONNS_PER_SERVER}
    }

[logging]
    kdc = STDERR
    admin_server = STDERR
    default = STDERR
EOF
}

# --------------------------------------------------------------------------
# Render the kadmind ACL file. kadmind refuses to start without it.
#   - KADM5_ACL (full content) overrides everything if set.
#   - otherwise: admins (*/admin) get all; an optional provisioner principal
#     (KRB5_PROVISIONER_PRINCIPAL, e.g. the LemonLDAP::NG service principal)
#     gets only add/changepw/modify/inquire.
# --------------------------------------------------------------------------
render_kadm5_acl() {
  local acl="${KDC_DIR}/kadm5.acl"
  log "Rendering ${acl}"
  if [ -n "${KADM5_ACL:-}" ]; then
    printf '%s\n' "$KADM5_ACL" > "$acl"
  else
    {
      echo "*/admin@${KRB5_REALM} *"
      if [ -n "${KRB5_PROVISIONER_PRINCIPAL:-}" ]; then
        echo "${KRB5_PROVISIONER_PRINCIPAL} acmi"
      fi
    } > "$acl"
  fi
}

# --------------------------------------------------------------------------
# Stash the LDAP service-account passwords used by krb5kdc / kadmind to bind.
# Format of the keyfile is managed by kdb5_ldap_util; we (re)create both
# entries on every boot so a rotated password just needs a restart.
# --------------------------------------------------------------------------
stash_service_passwords() {
  log "Stashing LDAP service passwords into ${SERVICE_KEYFILE}"
  rm -f "$SERVICE_KEYFILE"
  printf '%s\n%s\n' "$LDAP_KDC_PASSWORD" "$LDAP_KDC_PASSWORD" \
    | kdb5_ldap_util stashsrvpw -f "$SERVICE_KEYFILE" "$LDAP_KDC_DN" >/dev/null
  if [ "$LDAP_KADMIN_DN" != "$LDAP_KDC_DN" ]; then
    printf '%s\n%s\n' "$LDAP_KADMIN_PASSWORD" "$LDAP_KADMIN_PASSWORD" \
      | kdb5_ldap_util stashsrvpw -f "$SERVICE_KEYFILE" "$LDAP_KADMIN_DN" >/dev/null
  fi
  chmod 600 "$SERVICE_KEYFILE"
}

# --------------------------------------------------------------------------
# Optionally provision the realm container in LDAP (first boot only).
# --------------------------------------------------------------------------
create_realm() {
  if [ -z "$LDAP_ADMIN_DN" ] || [ -z "$LDAP_ADMIN_PASSWORD" ]; then
    log "ERROR: KRB5_CREATE_REALM=true requires LDAP_ADMIN_DN and LDAP_ADMIN_PASSWORD"
    exit 1
  fi
  local subtree_opt=()
  if [ -n "$LDAP_SUBTREES" ]; then
    subtree_opt=(-subtrees "$LDAP_SUBTREES")
  fi
  log "Creating realm ${KRB5_REALM} container in LDAP under ${LDAP_KERBEROS_CONTAINER_DN}"
  printf '%s\n%s\n' "$KRB5_MASTER_PASSWORD" "$KRB5_MASTER_PASSWORD" \
    | kdb5_ldap_util -D "$LDAP_ADMIN_DN" -w "$LDAP_ADMIN_PASSWORD" \
        create -r "$KRB5_REALM" "${subtree_opt[@]}" -s
}

realm_exists_in_ldap() {
  # `view` returns 0 iff the realm container already exists in LDAP.
  kdb5_ldap_util -D "$LDAP_ADMIN_DN" -w "$LDAP_ADMIN_PASSWORD" \
    view -r "$KRB5_REALM" >/dev/null 2>&1
}

# --------------------------------------------------------------------------
# Stash the KDB master key locally so daemons start without prompting.
# --------------------------------------------------------------------------
stash_master_key() {
  if [ -f "$STASH_MASTER" ]; then
    log "Master key stash already present (${STASH_MASTER})"
    return
  fi
  log "Stashing KDB master key into ${STASH_MASTER}"
  printf '%s\n' "$KRB5_MASTER_PASSWORD" | kdb5_util stash >/dev/null
}

# --------------------------------------------------------------------------
# Provision the keytab consumed by an external admin client (e.g. the
# LemonLDAP::NG provisioning plugin). Idempotent: generated once, then left
# untouched (re-running ktadd would rekey the principal and break the keytab
# already distributed). Put KRB5_PROVISIONER_KEYTAB on a volume shared with the
# consumer (read-only on its side). The principal also needs an ACL entry,
# granted via KRB5_PROVISIONER_PRINCIPAL in kadm5.acl.
# --------------------------------------------------------------------------
provision_keytab() {
  local princ="${KRB5_PROVISIONER_PRINCIPAL:-}"
  local keytab="${KRB5_PROVISIONER_KEYTAB:-}"
  { [ -n "$princ" ] && [ -n "$keytab" ]; } || return 0
  if [ -f "$keytab" ]; then
    log "Provisioner keytab already present (${keytab}); leaving it untouched"
    return 0
  fi
  log "Provisioning principal ${princ} and exporting keytab ${keytab}"
  mkdir -p "$(dirname "$keytab")"
  # Create with a random key if missing (ignore "already exists").
  kadmin.local -q "addprinc -randkey ${princ}" >/dev/null 2>&1 || true
  if kadmin.local -q "ktadd -k ${keytab} ${princ}" >/dev/null 2>&1; then
    chmod 640 "$keytab"
    log "Keytab written: ${keytab}"
  else
    log "WARN: failed to export keytab for ${princ}"
  fi
}

# --------------------------------------------------------------------------
# Main
# --------------------------------------------------------------------------
# Validate env, render configs and stash secrets. Service subcommands only.
setup() {
  load_config
  render_krb5_conf
  render_kdc_conf
  render_kadm5_acl
  stash_service_passwords

  if [ "$KRB5_CREATE_REALM" = "true" ]; then
    if realm_exists_in_ldap; then
      log "Realm ${KRB5_REALM} already exists in LDAP; skipping create"
      stash_master_key
    else
      create_realm
    fi
  else
    stash_master_key
  fi

  provision_keytab
}

main() {
  case "${1:-run}" in
    run)
      setup
      log "Starting krb5kdc + kadmind for realm ${KRB5_REALM}"
      # Run kadmind in the background, krb5kdc in the foreground (PID 1 child).
      kadmind -nofork &
      KADMIND_PID=$!
      trap 'kill -TERM "$KADMIND_PID" 2>/dev/null || true' TERM INT
      exec krb5kdc -n
      ;;
    kdc)
      setup
      exec krb5kdc -n
      ;;
    kadmin)
      setup
      exec kadmind -nofork
      ;;
    *)
      # Passthrough: one-off commands (zcat the schema, shell, kadmin.local in a
      # running container, …). No env required, no config rendered.
      exec "$@"
      ;;
  esac
}

main "$@"
