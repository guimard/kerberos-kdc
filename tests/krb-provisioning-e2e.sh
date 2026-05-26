#!/usr/bin/env bash
# Copyright (C) 2026 LINAGORA <https://linagora.com>
# Author: Xavier Guimard <xguimard@linagora.com>
# SPDX-License-Identifier: AGPL-3.0-or-later
#
# End-to-end integration test for the whole yadd/kdc stack + the
# LemonLDAP::NG krb-provisioning plugin.
#
# It drives a *real* portal login (Demo backend, account dwho/dwho) and proves
# that the plugin (re)sets the user's Kerberos key on the KDC at login time, so
# that `kinit` against this stack succeeds with the SSO password. It mirrors the
# plugin README's acceptance criteria:
#
#   1. First login   -> principal created, kinit succeeds.
#   2. Repeated login -> idempotent, kinit still succeeds.
#   3. Key drift      -> after a forced key change on the KDC, a new login
#                        resyncs the key (cpw), kinit succeeds again.
#   4. KDC down       -> SSO still succeeds, login is not blocked.
#   5. Password never appears in the portal logs.
#
# Usage:   tests/krb-provisioning-e2e.sh [--keep|--down]
#   --keep (default) leave the stack running afterwards
#   --down           docker compose down -v at the end
#
# Requires: docker (compose v2), curl. No host Kerberos client needed — all
# kinit/kadmin checks run inside the kdc container.
set -u

cd "$(dirname "$0")/.."

KEEP=1
[ "${1:-}" = "--down" ] && KEEP=0

HOST_HEADER="auth.example.com"
USER=dwho
PASS=dwho
REALM=EXAMPLE.COM

pass=0 fail=0
ok()   { printf '  \033[32mPASS\033[0m %s\n' "$1"; pass=$((pass+1)); }
ko()   { printf '  \033[31mFAIL\033[0m %s\n' "$1"; fail=$((fail+1)); }
step() { printf '\n\033[1m== %s\033[0m\n' "$1"; }

dc() { docker compose "$@"; }

# --- KDC-side helpers (run inside the kdc container, full local rights) -------
kdc_kadmin()   { dc exec -T kdc kadmin.local -q "$1" 2>&1; }
kdc_has()      { kdc_kadmin "getprinc $1" | grep -q "^Principal: $1@$REALM"; }
kdc_del()      { kdc_kadmin "delprinc -force $1" >/dev/null 2>&1 || true; }
kdc_setkey()   { kdc_kadmin "cpw -pw $2 $1" >/dev/null 2>&1; }
# kinit a principal with a given password, entirely inside the container.
kdc_kinit() {
  dc exec -T kdc bash -c 'kdestroy >/dev/null 2>&1; printf "%s" "$2" | kinit "$1" >/dev/null 2>&1 && klist 2>/dev/null | grep -q krbtgt' _ "$1" "$2"
}

# --- portal login: GET token (+cookie), POST credentials. Echoes HTTP code. ---
PORT=""
portal_url() { echo "http://localhost:${PORT}/"; }
portal_login() {
  local u="$1" p="$2" jar tok
  jar="$(mktemp)"
  tok="$(curl -s -c "$jar" -H "Host: $HOST_HEADER" "$(portal_url)" \
        | grep -oE 'name="token" value="[^"]*"' | sed -E 's/.*value="([^"]*)".*/\1/')"
  curl -s -o /dev/null -b "$jar" -c "$jar" -H "Host: $HOST_HEADER" \
       --data-urlencode "user=$u" --data-urlencode "password=$p" \
       --data-urlencode "token=$tok" -w '%{http_code}' "$(portal_url)"
  rm -f "$jar"
}
# A login is "accepted" when the portal answers 200 or 302 (cookie set on 302).
login_ok() { case "$1" in 200|302) return 0;; *) return 1;; esac; }

# ------------------------------------------------------------------ bring up ---
step "Bring up the stack (docker compose up -d --build)"
dc up -d --build || { echo "compose up failed"; exit 2; }

PORT="$(dc port llng 80 2>/dev/null | sed -E 's/.*:([0-9]+)$/\1/')"
[ -n "$PORT" ] || { echo "cannot determine published portal port"; exit 2; }
echo "portal published on host port $PORT"

step "Wait for readiness (KDC keytab + portal HTTP 200)"
ready=0
for _ in $(seq 1 60); do
  if dc exec -T kdc test -s /keytabs/llng-provision.keytab 2>/dev/null \
     && [ "$(curl -s -o /dev/null -w '%{http_code}' -H "Host: $HOST_HEADER" "$(portal_url)")" = "200" ]; then
    ready=1; break
  fi
  sleep 2
done
[ "$ready" = 1 ] && ok "stack is ready" || { ko "stack never became ready"; dc logs --tail=40 llng; exit 2; }

# ---------------------------------------------------------- 1. first login ----
step "1. First login provisions the principal"
kdc_del "$USER"
kdc_has "$USER" && ko "precondition: $USER should be absent" || ok "precondition: $USER absent in KDB"
code="$(portal_login "$USER" "$PASS")"
login_ok "$code" && ok "portal login accepted (HTTP $code)" || ko "portal login rejected (HTTP $code)"
kdc_has "$USER" && ok "$USER@$REALM created in KDB" || ko "$USER@$REALM NOT created"
kdc_kinit "$USER" "$PASS" && ok "kinit $USER / $PASS succeeds" || ko "kinit $USER / $PASS failed"

# ------------------------------------------------------- 2. repeated login ----
step "2. Repeated login is idempotent"
code="$(portal_login "$USER" "$PASS")"
login_ok "$code" && ok "second login accepted (HTTP $code)" || ko "second login rejected (HTTP $code)"
kdc_kinit "$USER" "$PASS" && ok "kinit still succeeds after re-login" || ko "kinit broke after re-login"

# ---------------------------------------------------------- 3. key resync ----
step "3. Login resyncs a drifted key (cpw)"
kdc_setkey "$USER" "STALE-$(date +%s)"
kdc_kinit "$USER" "$PASS" && ko "key was supposed to drift but kinit still works" \
                          || ok "after forced key change, kinit $USER / $PASS fails (drift)"
code="$(portal_login "$USER" "$PASS")"
login_ok "$code" && ok "resync login accepted (HTTP $code)" || ko "resync login rejected (HTTP $code)"
kdc_kinit "$USER" "$PASS" && ok "kinit $USER / $PASS works again (resynced)" || ko "resync did not restore the key"

# ----------------------------------------------------- 4. KDC down: no block --
step "4. Login stays non-blocking when the KDC is down"
dc stop kdc >/dev/null 2>&1
start=$(date +%s)
code="$(portal_login "$USER" "$PASS")"
elapsed=$(( $(date +%s) - start ))
login_ok "$code" && ok "login still accepted with KDC down (HTTP $code)" || ko "login failed with KDC down (HTTP $code)"
[ "$elapsed" -le 15 ] && ok "login not blocked (${elapsed}s <= 15s budget)" || ko "login blocked ${elapsed}s with KDC down"
dc start kdc >/dev/null 2>&1
for _ in $(seq 1 30); do dc exec -T kdc test -s /keytabs/llng-provision.keytab 2>/dev/null && break; sleep 1; done

# ------------------------------------------------ 5. password not in logs ----
step "5. The password never appears in the portal logs"
if dc logs llng 2>&1 | grep -qF "password=$PASS" || dc logs llng 2>&1 | grep -qE "\"password\"\s*:\s*\"$PASS\""; then
  ko "password value found in portal logs"
else
  ok "password value absent from portal logs"
fi

# ------------------------------------------------------------------ summary ---
step "Summary"
printf '  %d passed, %d failed\n' "$pass" "$fail"
if [ "$KEEP" = 0 ]; then echo "tearing down (--down)"; dc down -v >/dev/null 2>&1; else echo "stack left running (portal: $(portal_url), Host: $HOST_HEADER)"; fi
[ "$fail" = 0 ]
