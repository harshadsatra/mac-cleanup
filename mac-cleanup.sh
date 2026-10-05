#!/bin/bash
# ─────────────────────────────────────────────────────────────
#  mac-cleanup — configurable cache & dev-junk cleaner for macOS
#
#  Usage:
#    mac-cleanup.sh                 run enabled tasks (asks before quitting apps)
#    mac-cleanup.sh --dry-run       show what would be removed, delete nothing
#    mac-cleanup.sh --yes           don't ask; quit apps if QUIT_APPS allows
#    mac-cleanup.sh --only a,b      run only these tasks (ignores enable flags)
#    mac-cleanup.sh --list          list tasks and whether they're enabled
#    mac-cleanup.sh --report        show current sizes of everything it manages
#    mac-cleanup.sh --schedule      run weekly (default Sunday 11:00, see SCHEDULE_*)
#    mac-cleanup.sh --unschedule    remove the schedule
#    mac-cleanup.sh --config FILE   use a different config file
#
#  Config: ~/.config/mac-cleanup/mac-cleanup.conf (created on first run)
#  Works with the macOS built-in bash 3.2.
# ─────────────────────────────────────────────────────────────

SCRIPT_PATH="$(cd "$(dirname "$0")" && pwd)/$(basename "$0")"
SCRIPT_DIR="$(dirname "$SCRIPT_PATH")"
CONFIG="${MAC_CLEANUP_CONFIG:-$HOME/.config/mac-cleanup/mac-cleanup.conf}"
PLIST_LABEL="com.user.mac-cleanup"
PLIST="$HOME/Library/LaunchAgents/$PLIST_LABEL.plist"

ALL_TASKS="browser_cache chrome_webstorage chrome_ai_model claude_cache editor_cache app_cache zoom_cache whatsapp_media xcode android package_caches dev_caches docker_prune user_logs extra_paths"

# ── Defaults (overridden by config) ──────────────────────────
DRY_RUN=false; QUIT_APPS=ask; NOTIFY=true
LOG_FILE="$HOME/Library/Logs/mac-cleanup.log"
ENABLE_BROWSER_CACHE=""  # empty = follow the old ENABLE_CHROME_CACHE (see below)
BROWSERS="chrome brave edge arc vivaldi opera chromium"
ENABLE_CHROME_WEBSTORAGE=false; ENABLE_CHROME_AI_MODEL=true
CHROME_PROFILES_ONLY=""
ENABLE_CLAUDE_CACHE=true; ENABLE_EDITOR_CACHE=true; ENABLE_ZOOM_CACHE=false
ENABLE_APP_CACHE=true
APPS="slack discord teams notion figma postman linear obsidian github_desktop spotify"
ENABLE_DEV_CACHES=true
DEV_CACHES="bun deno yarn_berry uv poetry go cargo composer cocoapods swiftpm carthage expo electron node_gyp prisma corepack"
ENABLE_WHATSAPP_MEDIA=false; WHATSAPP_MEDIA_MAX_AGE_DAYS=30
ENABLE_XCODE=true; ENABLE_ANDROID=true; ANDROID_NDK_KEEP=1; ANDROID_NDK_PIN=""
ANDROID_CLEAN_GRADLE=true
ENABLE_PACKAGE_CACHES=true; ENABLE_DOCKER_PRUNE=false; DOCKER_PRUNE_VOLUMES=false
ENABLE_USER_LOGS=true; LOG_MAX_AGE_DAYS=30
ENABLE_EXTRA_PATHS=false; EXTRA_PATHS=()
EXTRA_PATH=""; CONDA_BIN=""
SCHEDULE_WEEKDAY=0; SCHEDULE_HOUR=11; SCHEDULE_MINUTE=0

# ── CLI ──────────────────────────────────────────────────────
ASSUME_YES=false; SCHEDULED=false; ONLY=""; ACTION=run; CLI_DRY=""
while [ $# -gt 0 ]; do
  case "$1" in
    -n|--dry-run)  CLI_DRY=true ;;
    -y|--yes)      ASSUME_YES=true ;;
    --scheduled)   SCHEDULED=true; ASSUME_YES=true ;;
    --only|--config)
      [ -n "$2" ] || { echo "$1 needs a value (try --help)"; exit 1; }
      if [ "$1" = --only ]; then ONLY="$2"; else CONFIG="$2"; fi; shift ;;
    --list)        ACTION=list ;;
    --report)      ACTION=report ;;
    --schedule)    ACTION=schedule ;;
    --unschedule)  ACTION=unschedule ;;
    -h|--help)     sed -n '2,19p' "$SCRIPT_PATH" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "Unknown option: $1 (try --help)"; exit 1 ;;
  esac
  shift
done
ONLY="$(echo "$ONLY" | sed 's/chrome_cache/browser_cache/')"  # old task name
for t in $(echo "$ONLY" | tr ',' ' '); do
  case " $ALL_TASKS " in *" $t "*) ;; *) echo "Unknown task: $t (see --list)"; exit 1 ;; esac
done

# ── Config ───────────────────────────────────────────────────
if [ ! -f "$CONFIG" ]; then
  mkdir -p "$(dirname "$CONFIG")"
  if [ -f "$SCRIPT_DIR/mac-cleanup.conf" ]; then
    cp "$SCRIPT_DIR/mac-cleanup.conf" "$CONFIG"
    echo "Created config at $CONFIG"
  fi
fi
# shellcheck disable=SC1090
[ -f "$CONFIG" ] && . "$CONFIG"
[ -n "$CLI_DRY" ] && DRY_RUN=true
# chrome_cache was renamed to browser_cache; keep honouring old configs
[ -z "$ENABLE_BROWSER_CACHE" ] && ENABLE_BROWSER_CACHE="${ENABLE_CHROME_CACHE:-true}"

export PATH="${EXTRA_PATH:+$EXTRA_PATH:}$PATH:/opt/homebrew/bin:/usr/local/bin"
# Make nvm-managed node/npm available (needed for scheduled runs)
if [ -s "$HOME/.nvm/nvm.sh" ] && ! command -v npm >/dev/null 2>&1; then
  . "$HOME/.nvm/nvm.sh" >/dev/null 2>&1
fi

# ── Output helpers ───────────────────────────────────────────
if [ -t 1 ]; then B=$'\033[1m'; D=$'\033[2m'; G=$'\033[32m'; Y=$'\033[33m'; R=$'\033[31m'; C=$'\033[36m'; N=$'\033[0m'
else B=; D=; G=; Y=; R=; C=; N=; fi

log()  { mkdir -p "$(dirname "$LOG_FILE")"; echo "$(date '+%F %T') $*" >> "$LOG_FILE"; }
say()  { echo "$*"; }
info() { echo "  ${D}$*${N}"; }
warn() { echo "  ${Y}! $*${N}"; log "WARN $*"; }

human() { # KB -> human readable
  awk -v k="${1:-0}" 'BEGIN{ if(k>=1048576) printf "%.1f GB", k/1048576;
    else if(k>=1024) printf "%.0f MB", k/1024; else printf "%d KB", k }'
}
size_kb() { # total KB of the given paths (missing paths = 0)
  local t=0 s p
  for p in "$@"; do
    [ -e "$p" ] || continue
    s=$(du -sk "$p" 2>/dev/null | awk '{print $1}')
    t=$((t + ${s:-0}))
  done
  echo "$t"
}
TILDE='~'  # bash 3.2 prints a literal backslash for ${p/#$HOME/\~}
is_true() { case "$1" in true|yes|1|on) return 0 ;; *) return 1 ;; esac; }
upper()   { echo "$1" | tr '[:lower:]' '[:upper:]'; }

TASK_FREED=0
TOTAL_FREED=0
SUMMARY=""

# Delete paths safely: only inside $HOME, never $HOME itself, no "..", "." or "//".
rmp() {
  local p kb
  for p in "$@"; do
    # trailing slashes would let "$HOME//" through and make rm follow symlinks
    while [ "${p%/}" != "$p" ]; do p="${p%/}"; done
    [ -e "$p" ] || continue
    case "$p" in
      "$HOME"/?*) ;;
      *) warn "refusing to delete outside home: $p"; continue ;;
    esac
    case "$p" in *"/../"*|*"/.."|*"/./"*|*"/."|*"//"*) warn "refusing unsafe path: $p"; continue ;; esac
    kb=$(size_kb "$p")
    if is_true "$DRY_RUN"; then
      info "would remove $(human "$kb")  ${p/#$HOME/$TILDE}"
    else
      rm -rf "$p" 2>/dev/null || warn "could not fully remove ${p/#$HOME/$TILDE} (Full Disk Access?)"
      kb=$((kb - $(size_kb "$p")))
      info "removed $(human "$kb")  ${p/#$HOME/$TILDE}"
      log "removed $kb KB $p"
    fi
    TASK_FREED=$((TASK_FREED + kb))
  done
}

# Run a cleanup command and measure how much a directory shrank.
run_measured() { # run_measured "<label>" "<dir-to-measure>" cmd args...
  local label="$1" dir="$2"; shift 2
  local before after
  before=$(size_kb "$dir")
  if is_true "$DRY_RUN"; then
    info "would run: $* ${D}($label, currently $(human "$before"))${N}"
    return
  fi
  "$@" >/dev/null 2>&1 || warn "$label: command reported an error"
  after=$(size_kb "$dir")
  [ "$after" -lt "$before" ] && TASK_FREED=$((TASK_FREED + before - after))
  info "$label: $(human "$before") → $(human "$after")"
  log "$label $before KB -> $after KB"
}

# ── App handling ─────────────────────────────────────────────
app_running() { pgrep -f "/Applications/$1.app/Contents/MacOS/" >/dev/null 2>&1; }

# Ensure an app is closed. Returns 1 if the task should be skipped.
ensure_closed() {
  local app="$1" i
  app_running "$app" || return 0
  if is_true "$DRY_RUN"; then info "($app is running — would need to quit it)"; return 0; fi
  if is_true "$SCHEDULED" || [ "$QUIT_APPS" = "no" ]; then
    warn "$app is running — skipped"; return 1
  fi
  if [ "$QUIT_APPS" = "ask" ] && ! is_true "$ASSUME_YES"; then
    printf "  %s is running. Quit it now? [y/N] " "$app"
    read -r ans </dev/tty
    case "$ans" in y|Y|yes) ;; *) warn "$app left open — skipped"; return 1 ;; esac
  fi
  osascript -e "quit app \"$app\"" >/dev/null 2>&1
  for i in 1 2 3 4 5 6 7 8 9 10; do app_running "$app" || return 0; sleep 1; done
  warn "$app did not quit — skipped"; return 1
}

# ── Tasks ────────────────────────────────────────────────────
AS="$HOME/Library/Application Support"
CA="$HOME/Library/Caches"
CHROME="$AS/Google/Chrome"

# Cache folder names shared by Chromium browsers and Electron apps (never logins or site data)
CHROMIUM_CACHE_DIRS="Cache|Code Cache|GPUCache|DawnCache|DawnGraphiteCache|DawnWebGPUCache|Service Worker/CacheStorage|Service Worker/ScriptCache"

rm_cache_dirs() { # rm_cache_dirs <dir>: remove the CHROMIUM_CACHE_DIRS inside it
  local sub
  while IFS= read -r sub; do rmp "$1/$sub"; done <<EOF
$(echo "$CHROMIUM_CACHE_DIRS" | tr '|' '\n')
EOF
}

chrome_profiles() { # chrome_profiles [root]: prints profile dirs, one per line
  local root="${1:-$CHROME}" d name
  for d in "$root/Default" "$root"/Profile\ *; do
    [ -d "$d" ] || continue
    name="$(basename "$d")"
    if [ -n "$CHROME_PROFILES_ONLY" ]; then
      case ",$CHROME_PROFILES_ONLY," in *",$name,"*) ;; *) continue ;; esac
    fi
    echo "$d"
  done
}

# key | app name (to quit) | profile root | extra cache paths (;-separated, removed whole)
# Missing browsers are skipped. Add a Chromium browser with one line.
BROWSER_TABLE="chrome|Google Chrome|$CHROME|$CA/Google/Chrome;$AS/Google/GoogleUpdater/crx_cache
brave|Brave Browser|$AS/BraveSoftware/Brave-Browser|$CA/BraveSoftware/Brave-Browser;$CA/com.brave.Browser
edge|Microsoft Edge|$AS/Microsoft Edge|$CA/Microsoft Edge;$CA/com.microsoft.edgemac
arc|Arc|$AS/Arc/User Data|$CA/Arc;$CA/company.thebrowser.Browser
vivaldi|Vivaldi|$AS/Vivaldi|$CA/Vivaldi;$CA/com.vivaldi.Vivaldi
opera|Opera|$AS/com.operasoftware.Opera|$CA/com.operasoftware.Opera
chromium|Chromium|$AS/Chromium|$CA/Chromium;$CA/org.chromium.Chromium"

desc_browser_cache="Chromium browser caches: Chrome, Brave, Edge, Arc, Vivaldi, Opera (keeps logins, history, site data)"
task_browser_cache() {
  local key app root extra p found=0
  while IFS='|' read -r key app root extra; do
    case " $BROWSERS " in *" $key "*) ;; *) continue ;; esac
    [ -d "$root" ] || continue
    found=1; info "$app"
    ensure_closed "$app" || continue
    while IFS= read -r p; do rm_cache_dirs "$p"; done <<EOF
$(chrome_profiles "$root")
EOF
    rmp "$root/GrShaderCache" "$root/GraphiteDawnCache" "$root/ShaderCache" "$root/component_crx_cache"
    while IFS= read -r p; do [ -n "$p" ] && rmp "$p"; done <<EOF
$(echo "$extra" | tr ';' '\n')
EOF
  done <<EOF
$BROWSER_TABLE
EOF
  [ $found -eq 1 ] || info "no supported browser found"
}

# key | app name (to quit) | data dir with Electron cache folders (or -) | extra cache paths (;-separated)
APP_TABLE="slack|Slack|$AS/Slack|$CA/com.tinyspeck.slackmacgap
discord|Discord|$AS/discord|$CA/com.hnc.Discord
teams|Microsoft Teams|-|$HOME/Library/Containers/com.microsoft.teams2/Data/Library/Caches
notion|Notion|$AS/Notion|$CA/notion.id
figma|Figma|$AS/Figma|$CA/com.figma.Desktop
postman|Postman|$AS/Postman|$CA/com.postmanlabs.mac
linear|Linear|$AS/Linear|$CA/com.linear
obsidian|Obsidian|$AS/obsidian|$CA/md.obsidian
github_desktop|GitHub Desktop|$AS/GitHub Desktop|$CA/com.github.GitHubClient
spotify|Spotify|-|$CA/com.spotify.client"

desc_app_cache="Slack, Discord, Teams, Notion, Figma, Postman, Spotify… caches (keeps logins, data)"
task_app_cache() {
  local key app dir extra p any found=0
  while IFS='|' read -r key app dir extra; do
    case " $APPS " in *" $key "*) ;; *) continue ;; esac
    any=0; [ "$dir" != - ] && [ -d "$dir" ] && any=1
    while IFS= read -r p; do [ -n "$p" ] && [ -e "$p" ] && any=1; done <<EOF
$(echo "$extra" | tr ';' '\n')
EOF
    [ $any -eq 1 ] || continue
    found=1; info "$app"
    ensure_closed "$app" || continue
    [ "$dir" != - ] && rm_cache_dirs "$dir"
    while IFS= read -r p; do [ -n "$p" ] && rmp "$p"; done <<EOF
$(echo "$extra" | tr ';' '\n')
EOF
  done <<EOF
$APP_TABLE
EOF
  [ $found -eq 1 ] || info "none of the listed apps found"
}

# dev_cache <key> "<command or empty>" <path>...
# Uses the tool's own clean command when installed, otherwise removes the paths.
dev_cache() {
  local key="$1" cmd="$2" p any=0; shift 2
  case " $DEV_CACHES " in *" $key "*) ;; *) return ;; esac
  for p in "$@"; do [ -e "$p" ] && any=1; done
  [ $any -eq 1 ] || return
  if [ -n "$cmd" ] && command -v "${cmd%% *}" >/dev/null 2>&1; then
    # shellcheck disable=SC2086
    run_measured "$key" "$1" $cmd
  else
    rmp "$@"
  fi
}

desc_dev_caches="Bun, Deno, uv, Go, Cargo, CocoaPods, SwiftPM, Expo, Electron… download caches"
task_dev_caches() {
  dev_cache bun        "bun pm cache rm"   "$HOME/.bun/install/cache"
  dev_cache deno       "deno clean"        "$CA/deno"
  dev_cache yarn_berry ""                  "$HOME/.yarn/berry/cache"
  dev_cache uv         "uv cache clean"    "$HOME/.cache/uv"
  dev_cache poetry     ""                  "$CA/pypoetry/cache" "$CA/pypoetry/artifacts"  # not virtualenvs
  dev_cache go         "go clean -cache"   "$CA/go-build"
  dev_cache cargo      ""                  "$HOME/.cargo/registry/cache" "$HOME/.cargo/git/db"
  dev_cache composer   ""                  "$HOME/.composer/cache" "$CA/composer"
  dev_cache cocoapods  ""                  "$CA/CocoaPods" "$HOME/.cocoapods/repos/master"  # legacy specs repo only
  dev_cache swiftpm    ""                  "$CA/org.swift.swiftpm"
  dev_cache carthage   ""                  "$CA/org.carthage.CarthageKit"
  dev_cache expo       ""                  "$HOME/.expo/ios-simulator-app-cache" "$HOME/.expo/android-apk-cache" "$HOME/.expo/expo-go"
  dev_cache electron   ""                  "$CA/electron" "$CA/electron-builder"
  dev_cache node_gyp   ""                  "$CA/node-gyp"
  dev_cache prisma     ""                  "$HOME/.cache/prisma"
  dev_cache corepack   ""                  "$HOME/.cache/node/corepack"
  # Not in the default DEV_CACHES: these are NOT re-downloaded automatically
  dev_cache playwright ""                  "$CA/ms-playwright"     # npx playwright install
  dev_cache puppeteer  ""                  "$HOME/.cache/puppeteer" # npx puppeteer browsers install
  dev_cache cypress    ""                  "$CA/Cypress"            # npx cypress install
}

desc_chrome_webstorage="Chrome site data / WebStorage (may sign you out of web apps)"
task_chrome_webstorage() {
  [ -d "$CHROME" ] || return
  ensure_closed "Google Chrome" || return
  local p
  while IFS= read -r p; do rmp "$p/WebStorage"; done <<EOF
$(chrome_profiles)
EOF
}

desc_chrome_ai_model="Chrome Gemini Nano model (weights.bin) + keep it from re-downloading"
task_chrome_ai_model() {
  if is_true "$DRY_RUN"; then
    info "would set policy GenAILocalFoundationalModelSettings=1"
  else
    defaults write com.google.Chrome GenAILocalFoundationalModelSettings -int 1 2>/dev/null
  fi
  [ -d "$CHROME/OptGuideOnDeviceModel" ] || { info "model not present"; return; }
  ensure_closed "Google Chrome" || return
  rmp "$CHROME/OptGuideOnDeviceModel"
}

desc_claude_cache="Claude desktop caches (never touches the Cowork VM)"
task_claude_cache() {
  local d="$HOME/Library/Application Support/Claude"
  [ -d "$d" ] || { info "Claude not found"; return; }
  ensure_closed "Claude" || return
  rmp "$d/Cache" "$d/Code Cache" "$d/GPUCache" "$d/DawnGraphiteCache" "$d/DawnWebGPUCache" \
      "$HOME/Library/Caches/com.anthropic.claudefordesktop" "$HOME/Library/Caches/com.anthropic.claudefordesktop.ShipIt"
}

desc_editor_cache="VS Code + Cursor caches (keeps settings, extensions, history)"
task_editor_cache() {
  local pair app dir sub
  for pair in "Visual Studio Code:Code" "Cursor:Cursor"; do
    app="${pair%%:*}"; dir="$HOME/Library/Application Support/${pair##*:}"
    [ -d "$dir" ] || continue
    ensure_closed "$app" || continue
    for sub in Cache CachedData CachedExtensionVSIXs CachedProfilesData "Code Cache" GPUCache \
               DawnGraphiteCache DawnWebGPUCache logs "Service Worker/CacheStorage"; do
      rmp "$dir/$sub"
    done
  done
}

desc_zoom_cache="Zoom caches and old installers (keeps recordings)"
task_zoom_cache() {
  local d="$HOME/Library/Application Support/zoom.us"
  [ -d "$d" ] || { info "Zoom not found"; return; }
  ensure_closed "zoom.us" || return
  rmp "$d/AutoUpdater" "$d/data/WebviewCache" "$HOME/Library/Caches/us.zoom.xos"
}

desc_whatsapp_media="WhatsApp media older than WHATSAPP_MEDIA_MAX_AGE_DAYS"
task_whatsapp_media() {
  local m="$HOME/Library/Group Containers/group.net.whatsapp.WhatsApp.shared/Message/Media"
  [ -d "$m" ] || { info "no WhatsApp media folder"; return; }
  ensure_closed "WhatsApp" || return
  local kb
  kb=$(find "$m" -type f -mtime +"$WHATSAPP_MEDIA_MAX_AGE_DAYS" -exec du -k {} + 2>/dev/null | awk '{s+=$1} END{print s+0}')
  if is_true "$DRY_RUN"; then
    info "would remove $(human "$kb") of media older than $WHATSAPP_MEDIA_MAX_AGE_DAYS days"
  else
    find "$m" -type f -mtime +"$WHATSAPP_MEDIA_MAX_AGE_DAYS" -delete 2>/dev/null \
      || warn "some files not removed (give Terminal Full Disk Access)"
    info "removed $(human "$kb") of old WhatsApp media"; log "whatsapp media $kb KB"
  fi
  TASK_FREED=$((TASK_FREED + kb))
}

desc_xcode="Xcode DerivedData, simulator caches, unavailable simulators"
task_xcode() {
  local dev="$HOME/Library/Developer"
  [ -d "$dev" ] || { info "Xcode data not found"; return; }
  rmp "$dev/Xcode/DerivedData" "$dev/CoreSimulator/Caches" "$dev/Xcode/iOS DeviceSupport" \
      "$HOME/Library/Caches/com.apple.dt.Xcode"
  if xcrun --find simctl >/dev/null 2>&1; then
    run_measured "unavailable simulators" "$dev/CoreSimulator/Devices" xcrun simctl delete unavailable
  fi
}

desc_android="Old Android NDK versions + Gradle caches"
task_android() {
  local ndk="$HOME/Library/Android/sdk/ndk"
  if [ -d "$ndk" ]; then
    local versions keep count v
    versions=$(ls -1 "$ndk" 2>/dev/null | grep -E '^[0-9]+\.' | sort -t. -k1,1n -k2,2n -k3,3n)
    count=$(echo "$versions" | grep -c . )
    keep=$(echo "$versions" | tail -n "$ANDROID_NDK_KEEP")
    for v in $versions; do
      echo "$keep" | grep -qx "$v" && continue
      case ",$ANDROID_NDK_PIN," in *",$v,"*) continue ;; esac
      rmp "$ndk/$v"
    done
    info "NDK: $count installed, keeping $(echo $keep | tr ' ' ',')${ANDROID_NDK_PIN:+ + pinned $ANDROID_NDK_PIN}"
  fi
  if is_true "$ANDROID_CLEAN_GRADLE"; then
    ensure_closed "Android Studio" || return
    # pkill, not `gradle --stop`: that only stops daemons of its own Gradle version
    if pgrep -f GradleDaemon >/dev/null 2>&1; then
      if is_true "$DRY_RUN"; then info "(Gradle daemon running — would stop it)"
      else pkill -f GradleDaemon 2>/dev/null; sleep 1; fi
    fi
    rmp "$HOME/.gradle/caches" "$HOME/.gradle/daemon"
  fi
}

desc_package_caches="pnpm / npm / yarn / pip / conda / Homebrew caches"
task_package_caches() {
  if command -v pnpm >/dev/null 2>&1; then
    run_measured "pnpm store" "$(pnpm store path 2>/dev/null || echo "$HOME/Library/pnpm/store")" pnpm store prune
  fi
  command -v npm  >/dev/null 2>&1 && run_measured "npm cache"  "$HOME/.npm/_cacache" npm cache clean --force
  if command -v yarn >/dev/null 2>&1; then
    run_measured "yarn cache" "$(yarn cache dir 2>/dev/null)" yarn cache clean
  fi
  if command -v pip3 >/dev/null 2>&1; then
    run_measured "pip cache" "$HOME/Library/Caches/pip" pip3 cache purge
  fi
  local conda="${CONDA_BIN:-$(command -v conda 2>/dev/null)}"
  if [ -n "$conda" ] && [ -x "$conda" ]; then
    local base; base="$("$conda" info --base 2>/dev/null)"
    run_measured "conda pkgs" "$base/pkgs" "$conda" clean --all -y
  fi
  if command -v brew >/dev/null 2>&1; then
    run_measured "Homebrew cache" "$(brew --cache)" brew cleanup --prune=all -s
  fi
}

desc_docker_prune="Docker/Colima: remove unused images, containers, build cache"
task_docker_prune() {
  command -v docker >/dev/null 2>&1 || { info "docker not installed"; return; }
  docker info >/dev/null 2>&1 || { info "Docker/Colima not running — skipped"; return; }
  local args="-af"; is_true "$DOCKER_PRUNE_VOLUMES" && args="-af --volumes"
  if is_true "$DRY_RUN"; then
    info "would run: docker system prune $args"
    docker system df 2>/dev/null | sed 's/^/    /'
    return
  fi
  local out; out=$(docker system prune $args 2>&1 | tail -1)
  info "$out"; log "docker prune: $out"
  info "Note: Colima's disk file (~/.colima) may not shrink until the VM is restarted."
}

desc_user_logs="~/Library/Logs files older than LOG_MAX_AGE_DAYS"
task_user_logs() {
  local d="$HOME/Library/Logs" kb
  kb=$(find "$d" -type f -mtime +"$LOG_MAX_AGE_DAYS" ! -path "$LOG_FILE" -exec du -k {} + 2>/dev/null | awk '{s+=$1} END{print s+0}')
  if is_true "$DRY_RUN"; then
    info "would remove $(human "$kb") of logs older than $LOG_MAX_AGE_DAYS days"
  else
    find "$d" -type f -mtime +"$LOG_MAX_AGE_DAYS" ! -path "$LOG_FILE" -delete 2>/dev/null
    info "removed $(human "$kb") of old logs"
  fi
  TASK_FREED=$((TASK_FREED + kb))
}

desc_extra_paths="Your own paths from EXTRA_PATHS in the config"
task_extra_paths() {
  [ ${#EXTRA_PATHS[@]} -eq 0 ] && { info "EXTRA_PATHS is empty"; return; }
  rmp "${EXTRA_PATHS[@]}"
}

# ── Commands ─────────────────────────────────────────────────
task_enabled() {
  local t="$1"
  if [ -n "$ONLY" ]; then case ",$ONLY," in *",$t,"*) return 0 ;; *) return 1 ;; esac; fi
  local v; eval "v=\${ENABLE_$(upper "$t"):-false}"
  is_true "$v"
}

cmd_list() {
  say "${B}Tasks${N}  ${D}(config: ${CONFIG/#$HOME/$TILDE})${N}"
  local t d
  for t in $ALL_TASKS; do
    eval "d=\$desc_$t"
    if task_enabled "$t"; then printf "  ${G}●${N} %-18s %s\n" "$t" "$d"
    else printf "  ${D}○ %-18s %s${N}\n" "$t" "$d"; fi
  done
}

cmd_report() {
  say "${B}Current sizes${N}"
  local AS="$HOME/Library/Application Support"
  local rows="Chrome (all)|$CHROME
Chrome AI model|$CHROME/OptGuideOnDeviceModel
Claude caches|$AS/Claude/Cache
Claude Cowork VM|$AS/Claude/vm_bundles
VS Code|$AS/Code
Cursor|$AS/Cursor
WhatsApp|$HOME/Library/Group Containers/group.net.whatsapp.WhatsApp.shared
Xcode simulators|$HOME/Library/Developer/CoreSimulator
Android SDK|$HOME/Library/Android/sdk
Gradle|$HOME/.gradle
pnpm|$HOME/Library/pnpm
npm|$HOME/.npm
Colima|$HOME/.colima
~/Library/Caches|$HOME/Library/Caches
~/Library/Logs|$HOME/Library/Logs"
  local label path
  while IFS='|' read -r label path; do
    [ -e "$path" ] || continue
    printf "  %-20s %10s\n" "$label" "$(human "$(size_kb "$path")")"
  done <<EOF
$rows
EOF
  say ""; df -h / | awk 'NR==2{print "  Disk: "$4" free of "$2}'
}

cmd_schedule() {
  mkdir -p "$(dirname "$PLIST")"
  cat > "$PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>$PLIST_LABEL</string>
  <key>ProgramArguments</key><array>
    <string>/bin/bash</string><string>$SCRIPT_PATH</string>
    <string>--scheduled</string><string>--config</string><string>$CONFIG</string>
  </array>
  <key>StartCalendarInterval</key><dict>
    <key>Weekday</key><integer>$SCHEDULE_WEEKDAY</integer><key>Hour</key><integer>$SCHEDULE_HOUR</integer><key>Minute</key><integer>$SCHEDULE_MINUTE</integer>
  </dict>
  <key>StandardOutPath</key><string>$HOME/Library/Logs/mac-cleanup.out.log</string>
  <key>StandardErrorPath</key><string>$HOME/Library/Logs/mac-cleanup.out.log</string>
</dict></plist>
EOF
  launchctl unload "$PLIST" 2>/dev/null
  launchctl load "$PLIST" && say "${G}Scheduled:${N} weekday $SCHEDULE_WEEKDAY (0=Sun) at $SCHEDULE_HOUR:$(printf %02d "$SCHEDULE_MINUTE"). Change SCHEDULE_* in the config and rerun --schedule"
  say "${D}Scheduled runs skip any app that is open instead of quitting it.${N}"
}

cmd_unschedule() {
  launchctl unload "$PLIST" 2>/dev/null; rm -f "$PLIST"; say "Schedule removed."
}

cmd_run() {
  local mode="Cleaning"; is_true "$DRY_RUN" && mode="Dry run — nothing will be deleted"
  say "${B}${C}mac-cleanup${N}  ${D}$mode${N}"
  log "=== run start (dry=$DRY_RUN scheduled=$SCHEDULED only=$ONLY)"
  local t d ran=0
  for t in $ALL_TASKS; do
    task_enabled "$t" || continue
    ran=1; eval "d=\$desc_$t"
    say ""; say "${B}▸ $t${N} ${D}— $d${N}"
    TASK_FREED=0
    "task_$t"
    TOTAL_FREED=$((TOTAL_FREED + TASK_FREED))
    SUMMARY="$SUMMARY$(printf '%-18s %10s' "$t" "$(human "$TASK_FREED")")
"
  done
  [ $ran -eq 0 ] && { say "No tasks enabled. Edit $CONFIG"; return; }
  say ""; say "${B}Summary${N}"
  printf "%s" "$SUMMARY" | sed 's/^/  /'
  local verb="Freed"; is_true "$DRY_RUN" && verb="Would free"
  say "  ${G}${B}$verb: $(human "$TOTAL_FREED")${N}"
  df -h / | awk 'NR==2{print "  Disk now: "$4" free"}'
  log "=== run end: $verb $TOTAL_FREED KB"
  if is_true "$NOTIFY" && command -v osascript >/dev/null 2>&1 && ! is_true "$DRY_RUN"; then
    osascript -e "display notification \"$verb $(human "$TOTAL_FREED")\" with title \"mac-cleanup\"" 2>/dev/null
  fi
}

case "$ACTION" in
  list) cmd_list ;; report) cmd_report ;;
  schedule) cmd_schedule ;; unschedule) cmd_unschedule ;;
  *) cmd_run ;;
esac
