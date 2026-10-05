#!/bin/bash
# Safety checks for mac-cleanup.sh, run against a throwaway HOME. Usage: ./test.sh
DIR="$(cd "$(dirname "$0")" && pwd)"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
H="$T/home"; mkdir -p "$H/keep" "$H/real" "$H/a"
cat > "$T/t.conf" <<'EOF'
NOTIFY=false
ENABLE_EXTRA_PATHS=true
EXTRA_PATHS=("$HOME//" "$HOME/" "$HOME/./" "$HOME/a/../" "$HOME/$UNSET_VAR/" "/tmp" "$HOME/real/")
EOF
fail=0; check() { if eval "$2"; then echo "ok   $1"; else echo "FAIL $1"; fail=1; fi; }

out=$(HOME="$H" bash "$DIR/mac-cleanup.sh" --yes --only extra_paths --config "$T/t.conf" 2>&1)
check "home survives"           '[ -d "$H/keep" ]'
check "real path removed"       '[ ! -e "$H/real" ]'
check "tilde shown without \\"  '! echo "$out" | grep -qF "\\~"'
check "--only typo rejected"    '! HOME="$H" bash "$DIR/mac-cleanup.sh" --only bogus --config "$T/t.conf" >/dev/null 2>&1'
check "bare --only rejected"    '! HOME="$H" bash "$DIR/mac-cleanup.sh" --only >/dev/null 2>&1'
exit $fail
