#!/command/with-contenv sh
# Copyright (C) 2026 LINAGORA <https://linagora.com>
# Author: Xavier Guimard <xguimard@linagora.com>
# SPDX-License-Identifier: AGPL-3.0-or-later
#
# s6 cont-init script for the yadd/lemonldap-ng-full image. Mounted into
# /etc/cont-init.d/ so it runs (as root) on every boot, AFTER the stock
# update-llng-conf (alphabetical order: pick a name that sorts last, e.g.
# "zz-krb-provisioning"). Two jobs:
#
#   1. Make the provisioner keytab readable by the portal worker (www-data)
#      WITHOUT loosening the keytab on the shared volume. The KDC writes it
#      root:root 0640 on a read-only mount; we copy it to a private,
#      www-data-owned 0600 file on tmpfs (/run is wiped each boot, re-copied
#      here every time, never persisted).
#   2. Enable and configure the krb-provisioning plugin in the live config via
#      the image's own updateConf helper (writes lmConf cfgNum 1 in place).
#
# All values are read from the environment so the compose file stays the single
# source of truth. KRB_* names are local to this script (not plugin config).
set -e

UPDATE_CONF=/usr/share/docker-llng/updateConf

SRC_KEYTAB="${KRB_SRC_KEYTAB:-/keytabs/llng-provision.keytab}"
DST_KEYTAB="${KRB_KEYTAB:-/run/lemonldap-ng/llng-provision.keytab}"

echo "[krb-provisioning] preparing keytab ${SRC_KEYTAB} -> ${DST_KEYTAB}"
if [ -r "$SRC_KEYTAB" ]; then
    install -d -m 0750 -o www-data -g www-data "$(dirname "$DST_KEYTAB")"
    install -m 0600 -o www-data -g www-data "$SRC_KEYTAB" "$DST_KEYTAB"
else
    echo "[krb-provisioning] WARNING: ${SRC_KEYTAB} not readable yet;" \
         "plugin will no-op until the KDC has provisioned it" >&2
fi

echo "[krb-provisioning] writing plugin configuration (cfgNum 1)"
"$UPDATE_CONF" set customPlugins             "::Plugins::KrbProvisioning"
"$UPDATE_CONF" set krbProvisioningActivation 1
"$UPDATE_CONF" set krbRealm                  "${KRB_REALM:?KRB_REALM required}"
"$UPDATE_CONF" set krbAdminServer            "${KRB_ADMIN_SERVER:?KRB_ADMIN_SERVER required}"
"$UPDATE_CONF" set krbServicePrincipal       "${KRB_SERVICE_PRINCIPAL:?KRB_SERVICE_PRINCIPAL required}"
"$UPDATE_CONF" set krbKeytab                 "$DST_KEYTAB"
"$UPDATE_CONF" set krbConnectTimeout         "${KRB_CONNECT_TIMEOUT:-5}"

echo "[krb-provisioning] done"
