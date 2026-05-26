# pure-kdc

MIT Kerberos KDC (`krb5kdc`) + admin server (`kadmind`) running in a container,
with the Kerberos database stored in an **external OpenLDAP** server via the
`kldap` backend. Everything is configured through environment variables; the
container itself is stateless apart from two local stash files.

## Architecture

```
   Kerberos clients                this container                external
  ┌────────────────┐   88/464/749  ┌───────────────────┐  LDAPS  ┌───────────────┐
  │ kinit / kadmin │ ────────────► │ krb5kdc + kadmind │ ──────► │   OpenLDAP    │
  └────────────────┘               │   (kldap plugin)  │         │ krbContainer  │
                                   └───────────────────┘         └───────────────┘
```

- Principals, policies and the master key live **in LDAP**, not in the container.
- The container only keeps, under `/etc/krb5kdc` (mount a volume):
  - `.k5.<REALM>` — local cache of the master key (so daemons start unattended)
  - `service.keyfile` — stashed LDAP bind passwords for the service accounts

## Prerequisites on the external OpenLDAP

1. **Kerberos schema loaded.** The KDC objectClasses (`krbContainer`,
   `krbPrincipal`, `krbPrincipalAux`, `krbRealmContainer`, `krbTicketPolicyAux`,
   …) and their attributes are **not** part of stock OpenLDAP. They come from
   the MIT Kerberos LDAP schema shipped with the `krb5-kdc-ldap` package (OID
   arc `2.16.840.1.113719.1.301`). The image keeps the files at the standard
   Debian path `/usr/share/doc/krb5-kdc-ldap/` (gzipped):
   - `kerberos.openldap.ldif.gz` — **cn=config / `slapd.d` form** (`olcSchemaConfig`), load with `ldapadd -Y EXTERNAL`
   - `kerberos.schema.gz` — legacy `slapd.conf` `include` form
   - `kerberos.ldif.gz` — legacy Novell `dn: cn=schema` / `changetype: modify` form (not cn=config)

   Extract it from the image and load it into your directory:

   ```bash
   # Pull the cn=config schema out of the image (decompress on the way out)
   docker run --rm pure-kdc:latest \
     sh -c 'zcat /usr/share/doc/krb5-kdc-ldap/kerberos.openldap.ldif.gz' > kerberos.ldif

   # Load it into a running OpenLDAP (run on the LDAP host, as the cn=config admin)
   ldapadd -Y EXTERNAL -H ldapi:/// -f kerberos.ldif
   ```

   > Or just use the **`pure-kdc-ldap`** image (see `ldap/`), which ships this
   > schema preloaded and creates the KDC service accounts for you.

   (On a non-slim OpenLDAP host the very same files are already at
   `/usr/share/doc/krb5-kdc-ldap/`; Debian *-slim images drop `/usr/share/doc`,
   which is why this image reinstalls the package to keep the schema.)
2. **Two service accounts** (regular LDAP entries with a password):
   - a read-only one for `krb5kdc` → `LDAP_KDC_DN`
   - a read-write one for `kadmind` → `LDAP_KADMIN_DN`
     Grant them ACLs on the Kerberos container subtree.
3. **TLS recommended.** Use `ldaps://` (or StartTLS) so bind passwords and key
   material never cross the wire in clear text. If the directory uses a private
   CA, mount it into `/usr/local/share/ca-certificates/` (see compose file).

## Environment variables

| Variable                                                              | Required | Description                                                            |
| --------------------------------------------------------------------- | -------- | ---------------------------------------------------------------------- |
| `KRB5_REALM`                                                          | ✅       | Kerberos realm, e.g. `EXAMPLE.COM`                                     |
| `LDAP_SERVERS`                                                        | ✅       | Space-separated LDAP URIs, e.g. `ldaps://ldap.example.com`             |
| `LDAP_KERBEROS_CONTAINER_DN`                                          | ✅       | DN of the Kerberos container, e.g. `cn=krbContainer,dc=example,dc=com` |
| `LDAP_KDC_DN` / `LDAP_KDC_PASSWORD`                                   | ✅       | Bind account for `krb5kdc` (read-only)                                 |
| `LDAP_KADMIN_DN` / `LDAP_KADMIN_PASSWORD`                             | ✅       | Bind account for `kadmind` (read-write)                                |
| `KRB5_MASTER_PASSWORD`                                                | ✅       | KDB master key passphrase                                              |
| `KRB5_KDC_HOSTNAME`                                                   |          | FQDN advertised in `krb5.conf` (default: container hostname)           |
| `KRB5_DOMAIN`                                                         |          | DNS domain for `[domain_realm]` (default: lowercased realm)            |
| `KRB5_CREATE_REALM`                                                   |          | `true` to provision the realm in LDAP on first boot                    |
| `LDAP_ADMIN_DN` / `LDAP_ADMIN_PASSWORD`                               |          | Admin bind, only needed when creating the realm                        |
| `LDAP_SUBTREES`                                                       |          | Subtree(s) holding principals (used at realm creation)                 |
| `KRB5_PROVISIONER_PRINCIPAL`                                          |          | Principal granted add/changepw/modify/inquire in `kadm5.acl` (e.g. the LemonLDAP::NG service principal) |
| `KADM5_ACL`                                                          |          | Full `kadm5.acl` content (overrides the generated default)             |
| `DNS_LOOKUP_KDC` / `DNS_LOOKUP_REALM`                                 |          | `true`/`false` (default `false`)                                       |
| `KRB5_MAX_LIFE`, `KRB5_MAX_RENEWABLE_LIFE`, `KRB5_SUPPORTED_ENCTYPES` |          | Realm tuning                                                           |

See `.env.example` for a complete template.

## Usage

```bash
cp .env.example .env        # then edit values
docker build -t pure-kdc:latest .
```

### Full self-contained stack (KDC + dedicated LDAP)

`docker-compose.yml` wires the **`pure-kdc-ldap`** image (`ldap/`, schema +
service accounts preloaded) together with the KDC. It provisions the realm on
first boot and is idempotent afterwards:

```bash
docker compose up -d --build

# smoke test: create a principal and get a ticket
docker compose exec kdc kadmin.local -q "addprinc -pw testpw alice"
docker compose exec kdc bash -c 'echo testpw | kinit alice && klist'
```

### End-to-end test with LemonLDAP::NG (on-the-fly provisioning)

The compose file also ships an **`llng`** service
(`yadd/lemonldap-ng-full`) carrying the
[`krb-provisioning`](https://github.com/linagora/lemonldap-ng-plugins) plugin.
It demonstrates the whole point of this stack: a user who only exists in the
general identity directory gets a Kerberos principal **the first time they log
in through the SSO**, with their key set to the password they just typed.

The portal uses its default **Demo** backend (`dwho/dwho`, `rtyler/rtyler`, …),
so a login carries a cleartext password the plugin can turn into a Kerberos
key. Two mounted files wire it up, with the compose file as the single source
of truth for the values:

- [`examples/llng-krb5.conf`](examples/llng-krb5.conf) — tells `libkadm5` where
  the KDC is (the AS exchange on `:88` needed before talking to `kadmind:749`).
- [`examples/llng-cont-init.sh`](examples/llng-cont-init.sh) — at boot, copies
  the shared provisioner keytab to a portal-private `0600` file and enables the
  plugin (`updateConf set …`). `KRB_SERVICE_PRINCIPAL` **must** equal the KDC's
  `KRB5_PROVISIONER_PRINCIPAL`.

```bash
docker compose up -d --build       # brings up ldap + kdc + llng

# log in once as dwho through the portal, then check the KDC issues tickets:
#   (the portal is published on http://localhost:8088/, vhost auth.example.com)
docker compose exec kdc bash -c 'echo dwho | kinit dwho && klist'
```

A scripted check covering the plugin's acceptance criteria (first-login
creation, idempotent re-login, key resync, non-blocking when the KDC is down,
password never logged) is in
[`tests/krb-provisioning-e2e.sh`](tests/krb-provisioning-e2e.sh):

```bash
./tests/krb-provisioning-e2e.sh          # leaves the stack up
./tests/krb-provisioning-e2e.sh --down   # tear everything down at the end
```

### First boot — create the realm in LDAP

Set `KRB5_CREATE_REALM=true` (and the `LDAP_ADMIN_*` vars) once, then run:

```bash
docker compose up
```

This runs `kdb5_ldap_util create`, which builds the realm container and stashes
the master key. **Afterwards set `KRB5_CREATE_REALM=false`** for normal runs.

### Normal run

```bash
docker compose up -d
```

### Administering principals

```bash
# Inside the container (uses LDAP backend directly, no network auth):
docker compose exec kdc kadmin.local

kadmin.local:  addprinc alice
kadmin.local:  addprinc -randkey host/server.example.com
kadmin.local:  ktadd -k /tmp/server.keytab host/server.example.com
```

## DNS records

Kerberos clients locate the KDC either from `krb5.conf` or via DNS SRV records.
A ready-to-edit BIND zone snippet is in [`dns/example.com.zone`](dns/example.com.zone):

```dns
; KDC host
kdc                     IN  A       10.0.0.10

; KDC location (AS/TGS) — port 88
_kerberos._udp          IN  SRV     0 0 88   kdc.example.com.
_kerberos._tcp          IN  SRV     0 0 88   kdc.example.com.

; Master KDC (password changes) — port 88
_kerberos-master._udp   IN  SRV     0 0 88   kdc.example.com.
_kerberos-master._tcp   IN  SRV     0 0 88   kdc.example.com.

; kpasswd — port 464
_kpasswd._udp           IN  SRV     0 0 464  kdc.example.com.
_kpasswd._tcp           IN  SRV     0 0 464  kdc.example.com.

; kadmin — port 749
_kerberos-adm._tcp      IN  SRV     0 0 749  kdc.example.com.

; Realm-of-host mapping (only consulted when dns_lookup_realm = true)
_kerberos               IN  TXT     "EXAMPLE.COM"
```

Add a matching **PTR** record in your reverse zone (`10  IN PTR kdc.example.com.`):
Kerberos is sensitive to forward/reverse name resolution. Enable DNS-based
discovery on clients by setting `dns_lookup_kdc = true` in their `krb5.conf`.

## Exposed ports

| Port | Proto   | Service                   |
| ---- | ------- | ------------------------- |
| 88   | tcp+udp | KDC (AS/TGS)              |
| 464  | tcp+udp | kpasswd (password change) |
| 749  | tcp     | kadmin (administration)   |

## License

Copyright (C) 2026 LINAGORA <https://linagora.com>
Author: Xavier Guimard <xguimard@linagora.com>

Licensed under the **GNU Affero General Public License v3.0 or later** — see [`LICENSE`](LICENSE).
