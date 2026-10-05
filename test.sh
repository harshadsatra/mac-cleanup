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

# Table-driven tasks. Uses apps/tools without a clean command so nothing real is touched.
AS="$H/Library/Application Support"
mkdir -p "$AS/Chromium/Profile 2/Code Cache" "$AS/Chromium/Profile 2/Local Storage" "$AS/Chromium/GrShaderCache" \
         "$AS/obsidian/GPUCache" "$AS/obsidian/IndexedDB" "$H/.expo/expo-go" "$H/.expo/state" \
         "$H/Library/Caches/pypoetry/cache" "$H/Library/Caches/pypoetry/virtualenvs"
cat > "$T/t2.conf" <<'EOF'
NOTIFY=false; QUIT_APPS=no
BROWSERS="chromium"; APPS="obsidian"; DEV_CACHES="expo poetry"
EOF
HOME="$H" bash "$DIR/mac-cleanup.sh" --yes --only browser_cache,app_cache,dev_caches --config "$T/t2.conf" >/dev/null 2>&1
check "browser cache removed"   '[ ! -e "$AS/Chromium/Profile 2/Code Cache" ] && [ ! -e "$AS/Chromium/GrShaderCache" ]'
check "browser site data kept"  '[ -d "$AS/Chromium/Profile 2/Local Storage" ]'
check "app cache removed"       '[ ! -e "$AS/obsidian/GPUCache" ] && [ -d "$AS/obsidian/IndexedDB" ]'
check "dev cache removed"       '[ ! -e "$H/.expo/expo-go" ] && [ ! -e "$H/Library/Caches/pypoetry/cache" ]'
check "dev state kept"          '[ -d "$H/.expo/state" ] && [ -d "$H/Library/Caches/pypoetry/virtualenvs" ]'
check "old chrome_cache name ok" 'HOME="$H" bash "$DIR/mac-cleanup.sh" --dry-run --only chrome_cache --config "$T/t2.conf" >/dev/null 2>&1'
check "--only typo rejected"   '! HOME="$H" bash "$DIR/mac-cleanup.sh" --only bogus --config "$T/t.conf" >/dev/null 2>&1'
check "bare --only rejected"    '! HOME="$H" bash "$DIR/mac-cleanup.sh" --only >/dev/null 2>&1'
exit $fail
