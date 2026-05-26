# Copyright (C) 2026 LINAGORA <https://linagora.com>
# Author: Xavier Guimard <xguimard@linagora.com>
# SPDX-License-Identifier: AGPL-3.0-or-later
#
# Free software under the GNU Affero General Public License v3 or later; see
# <https://www.gnu.org/licenses/>. Distributed WITHOUT ANY WARRANTY.
FROM debian:trixie-slim

LABEL org.opencontainers.image.title="yadd/ldap-krb" \
      org.opencontainers.image.description="Dedicated OpenLDAP backend for the yadd/kdc Kerberos KDC (Kerberos schema preloaded)"

ARG DEBIAN_FRONTEND=noninteractive

# slapd + ldap-utils + slappasswd; procps for clean slapd lifecycle in init.
RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        slapd \
        ldap-utils \
        procps \
        ca-certificates \
    # Pull ONLY the cn=config Kerberos schema out of krb5-kdc-ldap, without
    # installing the KDC daemons. kerberos.openldap.ldif is the olcSchemaConfig
    # form (kerberos.ldif is the legacy "dn: cn=schema" Novell form — not it).
    && mkdir -p /etc/ldap/schema \
    && cd /tmp && apt-get download krb5-kdc-ldap \
    && dpkg-deb --fsys-tarfile krb5-kdc-ldap_*.deb \
         | tar -xO ./usr/share/doc/krb5-kdc-ldap/kerberos.openldap.ldif.gz \
         | gunzip > /etc/ldap/schema/kerberos.openldap.ldif \
    && rm -f /tmp/krb5-kdc-ldap_*.deb \
    && rm -rf /var/lib/apt/lists/*

COPY docker-entrypoint.sh /usr/local/bin/docker-entrypoint.sh
RUN chmod +x /usr/local/bin/docker-entrypoint.sh

# 389 LDAP, 636 LDAPS (LDAPS requires mounting certs + config; see README).
EXPOSE 389/tcp 636/tcp

VOLUME ["/var/lib/ldap", "/etc/ldap/slapd.d"]

ENTRYPOINT ["/usr/local/bin/docker-entrypoint.sh"]
CMD ["slapd"]
