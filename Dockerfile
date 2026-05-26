# Copyright (C) 2026 LINAGORA <https://linagora.com>
# Author: Xavier Guimard <xguimard@linagora.com>
# SPDX-License-Identifier: AGPL-3.0-or-later
#
# Free software under the GNU Affero General Public License v3 or later; see
# <https://www.gnu.org/licenses/>. Distributed WITHOUT ANY WARRANTY.
FROM debian:trixie-slim

LABEL org.opencontainers.image.title="pure-kdc" \
      org.opencontainers.image.description="MIT Kerberos KDC + kadmind with an external OpenLDAP backend (kldap)" \
      org.opencontainers.image.source="https://github.com/linagora/pure-kdc"

ARG DEBIAN_FRONTEND=noninteractive

# krb5-kdc          -> krb5kdc daemon
# krb5-admin-server -> kadmind daemon + kadmin/kadmin.local
# krb5-kdc-ldap     -> kldap database plugin + kdb5_ldap_util
# krb5-user         -> kinit/klist/etc. (debug)
# ldap-utils        -> ldapsearch (debug / readiness checks)
# ca-certificates   -> validate LDAPS certificate of the external OpenLDAP
RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        krb5-kdc \
        krb5-admin-server \
        krb5-kdc-ldap \
        krb5-user \
        ldap-utils \
        ca-certificates \
    # The Kerberos LDAP schema ships under /usr/share/doc, which the Debian
    # *-slim base drops (path-exclude in /etc/dpkg/dpkg.cfg.d). Move that config
    # aside and reinstall krb5-kdc-ldap alone so its schema files land at the
    # standard /usr/share/doc/krb5-kdc-ldap/ path, then restore the exclude.
    && mv /etc/dpkg/dpkg.cfg.d /tmp/dpkg.cfg.d \
    && apt-get install -y --reinstall --no-install-recommends krb5-kdc-ldap \
    && mv /tmp/dpkg.cfg.d /etc/dpkg/dpkg.cfg.d \
    && rm -rf /var/lib/apt/lists/*

COPY docker-entrypoint.sh /usr/local/bin/docker-entrypoint.sh
RUN chmod +x /usr/local/bin/docker-entrypoint.sh

# 88   : KDC (AS/TGS)            tcp+udp
# 464  : kpasswd (set password)  tcp+udp
# 749  : kadmin (administration)  tcp
EXPOSE 88/tcp 88/udp 464/tcp 464/udp 749/tcp

# Holds generated configs + stash files (master key + LDAP service passwords).
# Mount a named volume here so stashes survive restarts.
VOLUME ["/etc/krb5kdc"]

ENTRYPOINT ["/usr/local/bin/docker-entrypoint.sh"]
CMD ["run"]
