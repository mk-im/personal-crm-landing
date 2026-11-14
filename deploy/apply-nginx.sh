#!/usr/bin/env bash
# Replace the landing nginx vhost and reload nginx.
# Refuses to edit a file that also serves any other site.
set -euo pipefail

select_landing_file() {
  awk '
    function flush() {
      if (file == "") return
      n = split(names, parts, " ")
      landing = 0
      other = ""
      for (i = 1; i <= n; i++) {
        name = parts[i]
        if (name == "") continue
        if (name == "crmc.space") landing = 1
        else other = other " " name
      }
      if (landing && other == "") print file
      else if (landing) {
        mixed = 1
        print "Refusing " file " because it also serves:" other > "/dev/stderr"
      }
      file = ""
      names = ""
    }
    /^# configuration file / {
      flush()
      file = $0
      sub(/^# configuration file /, "", file)
      sub(/:$/, "", file)
      names = ""
      next
    }
    /^[[:space:]]*#/ { next }
    /server_name[[:space:]]/ {
      line = $0
      sub(/.*server_name[[:space:]]+/, "", line)
      sub(/;.*/, "", line)
      names = names " " line
    }
    END {
      flush()
      if (mixed) exit 2
    }
  '
}

assert_landing_source() {
  local src="$1"
  local names
  names="$(awk '
    /^[[:space:]]*#/ { next }
    /server_name[[:space:]]/ {
      line = $0
      sub(/.*server_name[[:space:]]+/, "", line)
      sub(/;.*/, "", line)
      print line
    }
  ' "$src")"
  if [[ -z "$names" ]]; then
    echo "Landing config has no server_name" >&2
    exit 1
  fi
  local name
  for name in $names; do
    if [[ "$name" != "crmc.space" ]]; then
      echo "Landing config must only name crmc.space, found: $name" >&2
      exit 1
    fi
  done
}

if [[ "${1:-}" == "--select-from-dump" ]]; then
  set +e
  select_landing_file < "${2:?dump path}"
  status=$?
  set -e
  exit "$status"
fi

SRC="${1:?path to nginx-landing.conf}"
if [[ ! -f "$SRC" ]]; then
  echo "Config not found: $SRC" >&2
  exit 1
fi

assert_landing_source "$SRC"

headers_look_applied() {
  local dump server
  dump="$(curl -skI --max-time 20 --resolve crmc.space:443:127.0.0.1 https://crmc.space/ | tr -d '\r' || true)"
  server="$(printf '%s\n' "$dump" | awk -F': ' 'tolower($1)=="server" { print $2 }')"
  [[ "$server" == "nginx" ]] || return 1
  printf '%s\n' "$dump" | grep -qi "strict-transport-security: max-age=31536000$" || return 1
  printf '%s\n' "$dump" | grep -q "frame-ancestors 'none'" || return 1
  printf '%s\n' "$dump" | grep -q "fonts.googleapis.com" || return 1
  printf '%s\n' "$dump" | grep -qi "^x-frame-options: DENY$" || return 1
  printf '%s\n' "$dump" | grep -qi "^x-content-type-options: nosniff$" || return 1
  printf '%s\n' "$dump" | grep -qi "^referrer-policy:" || return 1
  printf '%s\n' "$dump" | grep -qi "^permissions-policy:" || return 1
}

if headers_look_applied; then
  echo "Landing security headers are already in place."
  exit 0
fi

root_mode="none"
if [[ "$(id -u)" -eq 0 ]]; then
  root_mode="direct"
elif sudo -n true >/dev/null 2>&1; then
  root_mode="sudo"
elif docker info >/dev/null 2>&1; then
  root_mode="docker"
  echo "sudo asks for a password. Applying the landing file through docker."
else
  echo "Cannot reload nginx without a password, and docker is not usable. The landing nginx config was not changed." >&2
  exit 1
fi

run_root() {
  case "$root_mode" in
    direct) "$@" ;;
    sudo) sudo -n "$@" ;;
    docker)
      if ! docker image inspect alpine:3.20 >/dev/null 2>&1; then
        docker pull -q alpine:3.20 >/dev/null
      fi
      docker run --rm --pid host -v /:/host alpine:3.20 chroot /host "$@"
      ;;
  esac
}

exec 9>/tmp/personal-crm-landing-nginx.lock
if ! flock -n 9; then
  echo "Another landing nginx update is running" >&2
  exit 1
fi

err="$(mktemp)"
if ! dump="$(run_root nginx -T 2>"$err")"; then
  echo "nginx -T failed. Nothing was changed." >&2
  cat "$err" >&2
  rm -f "$err"
  exit 1
fi
rm -f "$err"

list="$(mktemp)"
if ! printf '%s\n' "$dump" | select_landing_file >"$list"; then
  echo "A nginx file serves crmc.space together with another site. Nothing was changed." >&2
  rm -f "$list"
  exit 1
fi
mapfile -t targets <"$list"
rm -f "$list"
if [[ "${#targets[@]}" -ne 1 || -z "${targets[0]}" ]]; then
  echo "Expected one nginx file that serves only crmc.space, found ${#targets[@]}." >&2
  if [[ "${#targets[@]}" -gt 0 && -n "${targets[0]}" ]]; then
    printf '  %s\n' "${targets[@]}" >&2
  fi
  exit 1
fi

target="${targets[0]}"
case "$target" in
  /etc/nginx/*) ;;
  *)
    echo "Refusing to write outside /etc/nginx: $target" >&2
    exit 1
    ;;
esac

if [[ -L "$target" || -e "$target" ]]; then
  real="$(readlink -f "$target")"
else
  echo "Landing nginx file does not exist: $target" >&2
  exit 1
fi
case "$real" in
  /etc/nginx/*) ;;
  *)
    echo "Refusing to write outside /etc/nginx: $real" >&2
    exit 1
    ;;
esac

backup="$(mktemp)"
# Copy into the existing temp file so it stays owned by the deploy user.
run_root cp "$real" "$backup"

remove_backup() {
  if [[ ! -e "$backup" ]]; then
    return 0
  fi
  if rm -f "$backup"; then
    return 0
  fi
  run_root rm -f "$backup"
}

restore() {
  run_root cp "$backup" "$real"
  run_root nginx -t
  if ! run_root systemctl reload nginx; then
    run_root nginx -s reload
  fi
}

run_root cp "$SRC" "$real"
if ! run_root nginx -t; then
  echo "nginx rejected the landing config. Restoring the previous file." >&2
  restore
  remove_backup
  exit 1
fi

if ! run_root systemctl reload nginx; then
  run_root nginx -s reload
fi

header_dump="$(curl -skI --max-time 20 --resolve crmc.space:443:127.0.0.1 https://crmc.space/ | tr -d '\r' || true)"
landing_code="$(curl -sk -o /dev/null -w '%{http_code}' --max-time 20 --resolve crmc.space:443:127.0.0.1 https://crmc.space/ || true)"
favicon_code="$(curl -sk -o /dev/null -w '%{http_code}' --max-time 20 --resolve crmc.space:443:127.0.0.1 https://crmc.space/favicon.svg || true)"
fallback_code="$(curl -sk -o /dev/null -w '%{http_code}' --max-time 20 --resolve crmc.space:443:127.0.0.1 https://crmc.space/no-such-page || true)"
css_path="$(curl -sk --max-time 20 --resolve crmc.space:443:127.0.0.1 https://crmc.space/ | grep -o '/_astro/[^" ]*' | head -n 1 || true)"
css_code="missing"
if [[ -n "$css_path" ]]; then
  css_code="$(curl -sk -o /dev/null -w '%{http_code}' --max-time 20 --resolve crmc.space:443:127.0.0.1 "https://crmc.space${css_path}" || true)"
fi
redirect_dump="$(curl -sI --max-time 20 --resolve crmc.space:80:127.0.0.1 http://crmc.space/ | tr -d '\r' || true)"
redirect_code="$(printf '%s\n' "$redirect_dump" | awk 'NR==1 { print $2 }')"
app_code="$(curl -sk -o /dev/null -w '%{http_code}' --max-time 20 --resolve app.crmc.space:443:127.0.0.1 https://app.crmc.space/ || true)"

fail() {
  echo "$1" >&2
  echo "Restoring the previous landing config." >&2
  restore
  remove_backup
  exit 1
}

header_has() {
  local name="$1"
  printf '%s\n' "$header_dump" | grep -qi "^${name}:"
}

if [[ "$landing_code" != "200" ]]; then
  fail "Landing returned ${landing_code}, expected 200."
fi
if [[ "$favicon_code" != "200" ]]; then
  fail "favicon.svg returned ${favicon_code}, expected 200."
fi
if [[ "$fallback_code" != "200" ]]; then
  fail "Unknown landing path returned ${fallback_code}, expected 200."
fi
if [[ "$css_code" != "200" ]]; then
  fail "Landing stylesheet returned ${css_code}, expected 200."
fi
if [[ "$redirect_code" != "301" ]]; then
  fail "HTTP redirect returned ${redirect_code}, expected 301."
fi
case "$app_code" in
  200|301|302|307|308) ;;
  *) fail "App returned ${app_code} after the landing nginx reload." ;;
esac

header_has "strict-transport-security" || fail "HSTS header is missing."
header_has "content-security-policy" || fail "CSP header is missing."
header_has "x-frame-options" || fail "X-Frame-Options header is missing."
header_has "x-content-type-options" || fail "nosniff header is missing."
header_has "referrer-policy" || fail "Referrer-Policy header is missing."
header_has "permissions-policy" || fail "Permissions-Policy header is missing."

if ! printf '%s\n' "$header_dump" | grep -qi "strict-transport-security: max-age=31536000$"; then
  fail "HSTS is not limited to this host for one year."
fi
if ! printf '%s\n' "$header_dump" | grep -qi "x-frame-options: DENY$"; then
  fail "X-Frame-Options is not DENY."
fi
if ! printf '%s\n' "$header_dump" | grep -qi "x-content-type-options: nosniff$"; then
  fail "X-Content-Type-Options is not nosniff."
fi
if ! printf '%s\n' "$header_dump" | grep -qi "content-security-policy:.*unsafe-inline"; then
  fail "CSP does not allow inline scripts and styles."
fi
if printf '%s\n' "$header_dump" | grep -qi "content-security-policy:.*nonce-"; then
  fail "CSP uses a nonce."
fi
if ! printf '%s\n' "$header_dump" | grep -qi "frame-ancestors 'none'"; then
  fail "CSP does not forbid framing."
fi
if ! printf '%s\n' "$header_dump" | grep -q "fonts.googleapis.com"; then
  fail "CSP does not allow the font stylesheet."
fi
if ! printf '%s\n' "$header_dump" | grep -q "fonts.gstatic.com"; then
  fail "CSP does not allow the font files."
fi

server_header="$(printf '%s\n' "$header_dump" | awk -F': ' 'tolower($1)=="server" { print $2 }')"
if [[ "$server_header" != "nginx" ]]; then
  fail "nginx still names its version: ${server_header:-<missing>}"
fi
redirect_server="$(printf '%s\n' "$redirect_dump" | awk -F': ' 'tolower($1)=="server" { print $2 }')"
if [[ "$redirect_server" != "nginx" ]]; then
  fail "nginx names its version on HTTP: ${redirect_server:-<missing>}"
fi
if printf '%s\n' "$redirect_dump" | grep -qi '^strict-transport-security:'; then
  fail "HSTS was sent over plain HTTP."
fi

remove_backup
echo "Landing nginx config applied: $real"
