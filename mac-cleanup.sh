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
#    mac-cleanup.sh --schedule      run automatically every Sunday at 11:00
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

ALL_TASKS="chrome_cache chrome_webstorage chrome_ai_model claude_cache editor_cache zoom_cache whatsapp_media xcode android package_caches docker_prune user_logs extra_paths"

# ── Defaults (overridden by config) ──────────────────────────
DRY_RUN=false; QUIT_APPS=ask; NOTIFY=true
LOG_FILE="$HOME/Library/Logs/mac-cleanup.log"
ENABLE_CHROME_CACHE=true; ENABLE_CHROME_WEBSTORAGE=false; ENABLE_CHROME_AI_MODEL=true
CHROME_PROFILES_ONLY=""
ENABLE_CLAUDE_CACHE=true; ENABLE_EDITOR_CACHE=true; ENABLE_ZOOM_CACHE=false
ENABLE_WHATSAPP_MEDIA=false; WHATSAPP_MEDIA_MAX_AGE_DAYS=30
ENABLE_XCODE=true; ENABLE_ANDROID=true; ANDROID_NDK_KEEP=1; ANDROID_NDK_PIN=""
ANDROID_CLEAN_GRADLE=true
ENABLE_PACKAGE_CACHES=true; ENABLE_DOCKER_PRUNE=false; DOCKER_PRUNE_VOLUMES=false
ENABLE_USER_LOGS=true; LOG_MAX_AGE_DAYS=30
ENABLE_EXTRA_PATHS=false; EXTRA_PATHS=()
EXTRA_PATH=""; CONDA_BIN=""

# ── CLI ──────────────────────────────────────────────────────
ASSUME_YES=false; SCHEDULED=false; ONLY=""; ACTION=run; CLI_DRY=""
while [ $# -gt 0 ]; do
  case "$1" in
    -n|--dry-run)  CLI_DRY=true ;;
    -y|--yes)      ASSUME_YES=true ;;
    --scheduled)   SCHEDULED=true; ASSUME_YES=true ;;
    --only)        ONLY="$2"; shift ;;
    --config)      CONFIG="$2"; shift ;;
    --list)        ACTION=list ;;
    --report)      ACTION=report ;;
    --schedule)    ACTION=schedule ;;
    --unschedule)  ACTION=unschedule ;;
    -h|--help)     sed -n '2,19p' "$SCRIPT_PATH" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "Unknown option: $1 (try --help)"; exit 1 ;;
  esac
  shift
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

export PATH="$EXTRA_PATH:$PATH:/opt/homebrew/bin:/usr/local/bin"
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
is_true() { case "$1" in true|yes|1|on) return 0 ;; *) return 1 ;; esac; }
upper()   { echo "$1" | tr '[:lower:]' '[:upper:]'; }

TASK_FREED=0
TOTAL_FREED=0
SUMMARY=""

# Delete paths safely: only inside $HOME, never $HOME itself, no "..".
rmp() {
  local p kb
  for p in "$@"; do
    [ -e "$p" ] || continue
    case "$p" in
      "$HOME"/?*) ;;
      *) warn "refusing to delete outside home: $p"; continue ;;
    esac
    case "$p" in *"/../"*|*"/..") warn "refusing path with ..: $p"; continue ;; esac
    kb=$(size_kb "$p")
    if is_true "$DRY_RUN"; then
      info "would remove $(human "$kb")  ${p/#$HOME/\~}"
    else
      rm -rf "$p" 2>/dev/null || warn "could not fully remove ${p/#$HOME/\~} (Full Disk Access?)"
      info "removed $(human "$kb")  ${p/#$HOME/\~}"
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
CHROME="$HOME/Library/Application Support/Google/Chrome"

chrome_profiles() { # prints profile dirs, one per line
  local d name
  for d in "$CHROME/Default" "$CHROME"/Profile\ *; do
    [ -d "$d" ] || continue
    name="$(basename "$d")"
    if [ -n "$CHROME_PROFILES_ONLY" ]; then
      case ",$CHROME_PROFILES_ONLY," in *",$name,"*) ;; *) continue ;; esac
    fi
    echo "$d"
  done
}

desc_chrome_cache="Chrome caches in every profile (keeps logins, history, site data)"
task_chrome_cache() {
  [ -d "$CHROME" ] || { info "Chrome not found"; return; }
  ensure_closed "Google Chrome" || return
  local p
  while IFS= read -r p; do
    rmp "$p/Cache" "$p/Code Cache" "$p/GPUCache" "$p/DawnCache" "$p/DawnGraphiteCache" \
        "$p/DawnWebGPUCache" "$p/Service Worker/CacheStorage" "$p/Service Worker/ScriptCache"
  done <<EOF
$(chrome_profiles)
EOF
  rmp "$CHROME/GrShaderCache" "$CHROME/GraphiteDawnCache" "$CHROME/ShaderCache" \
      "$CHROME/component_crx_cache" "$HOME/Library/Application Support/Google/GoogleUpdater/crx_cache"
  local c; for c in "$HOME/Library/Caches/Google/Chrome"/*; do rmp "$c"; done
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
    if pgrep -f GradleDaemon >/dev/null 2>&1; then
      if is_true "$DRY_RUN"; then info "(Gradle daemon running — would stop it)"
      elif command -v gradle >/dev/null 2>&1; then gradle --stop >/dev/null 2>&1
      else pkill -f GradleDaemon 2>/dev/null; fi
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
  say "${B}Tasks${N}  ${D}(config: ${CONFIG/#$HOME/\~})${N}"
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
    <key>Weekday</key><integer>0</integer><key>Hour</key><integer>11</integer><key>Minute</key><integer>0</integer>
  </dict>
  <key>StandardOutPath</key><string>$HOME/Library/Logs/mac-cleanup.out.log</string>
  <key>StandardErrorPath</key><string>$HOME/Library/Logs/mac-cleanup.out.log</string>
</dict></plist>
EOF
  launchctl unload "$PLIST" 2>/dev/null
  launchctl load "$PLIST" && say "${G}Scheduled:${N} every Sunday at 11:00. Edit the time in ${PLIST/#$HOME/\~}"
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
