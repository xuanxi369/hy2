#!/usr/bin/env bash
set -Eeuo pipefail
# shellcheck source=hy2-secure.sh
source "$(dirname "$0")/hy2-secure.sh"
trap - ERR INT TERM

fail(){ echo "FAIL: $*" >&2; exit 1; }
assert_ok(){ "$@" || fail "expected success: $*"; }
assert_bad(){ if "$@"; then fail "expected failure: $*"; fi; }
assert_contains(){ grep -Fq -- "$2" "$1" || fail "$1 missing: $2"; }
assert_not_contains(){ if grep -Fq -- "$2" "$1"; then fail "$1 unexpectedly contains: $2"; fi; }

assert_ok validate_port 1
assert_ok validate_port 443
assert_ok validate_port 65535
assert_bad validate_port 0
assert_bad validate_port 65536
assert_bad validate_port abc
assert_ok validate_version v2.10.0
assert_bad validate_version latest
assert_ok validate_domain example.com
assert_bad validate_domain bad_domain
assert_ok validate_bandwidth '100 mbps'
assert_bad validate_bandwidth 'fast'
[[ $(yaml_quote "a'b") == "'a''b'" ]] || fail 'YAML quote'
[[ $(release_base) == 'https://github.com/apernet/hysteria/releases/download/app/v2.10.0' ]] || fail 'release URL'

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
cat >"$work/hashes.txt" <<'EOF'
aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa  build/hysteria-linux-amd64-avx
bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb  build/hysteria-linux-amd64
cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc  ./hysteria-linux-arm64
EOF
[[ $(extract_expected_hash "$work/hashes.txt" hysteria-linux-amd64) == bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb ]] || fail 'GNU hashes path parsing'
[[ $(extract_expected_hash "$work/hashes.txt" hysteria-linux-amd64-avx) == aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa ]] || fail 'exact asset matching'
printf 'SHA256 (dist/hysteria-linux-amd64) = %064d\n' 0 >"$work/hashes-bsd.txt"
[[ $(extract_expected_hash "$work/hashes-bsd.txt" hysteria-linux-amd64) == $(printf '%064d' 0) ]] || fail 'BSD hashes parsing'

SET_PORT=8443; SET_PASS="p'a:ss#word"; CERT_TYPE=selfsigned; SELF_CN=example.com
RUN_MODE=STANDARD; BW_UP='100 mbps'; BW_DOWN=''; IGNORE_CLIENT_BW=false
ENABLE_OBFS=1; OBFS_PASS="ob'fs"; PROTECT_PRIVATE=1; MASQ_ENABLE=0
generate_config "$work/config.yaml"
assert_contains "$work/config.yaml" "listen: ':8443'"
assert_contains "$work/config.yaml" "password: 'p''a:ss#word'"
assert_contains "$work/config.yaml" 'reject(10.0.0.0/8)'
assert_contains "$work/config.yaml" 'reject(fc00::/7)'
assert_not_contains "$work/config.yaml" 'reject(cidr:'

RAM_MB=512; LOG_TO_FILE=0
generate_unit "$work/hy2.service"
assert_contains "$work/hy2.service" 'User=hy2'
assert_contains "$work/hy2.service" 'CapabilityBoundingSet=CAP_NET_BIND_SERVICE'
assert_not_contains "$work/hy2.service" 'CAP_NET_ADMIN'

bash -n "$(dirname "$0")/hy2-secure.sh"
echo 'PASS: all tests'
