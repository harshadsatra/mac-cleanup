# mac-cleanup

A configurable cleanup script for macOS developers. It removes caches and build data that rebuild themselves, so your Mac stays light without your logins, settings or projects being touched.

It's built for a typical web and mobile dev setup: Chrome, Brave and other Chromium browsers, Claude, VS Code and Cursor, Slack/Discord/Notion-style apps, Xcode, Android and React Native/Expo, Node, Python, Go and Rust tooling, Homebrew and Docker/Colima.

```
mac-cleanup  Cleaning

▸ browser_cache — Chromium browser caches: Chrome, Brave, Edge, Arc, Vivaldi, Opera (keeps logins, history, site data)
  removed 1.2 GB  ~/Library/Caches/Google/Chrome/Default
▸ android — Old Android NDK versions + Gradle caches
  removed 2.1 GB  ~/Library/Android/sdk/ndk/25.1.8937393
  NDK: 5 installed, keeping 27.1.12297006
...
Summary
  browser_cache         1.9 GB
  android               9.8 GB
  package_caches        6.4 GB
  Freed: 18.1 GB
```

## Features

- **Configurable.** Turn each task on or off in one config file.
- **Dry-run mode.** See exactly what would be removed and how big it is before deleting anything.
- **Safe by default.** Only caches that rebuild themselves are on out of the box. Anything that could sign you out or lose data is off until you turn it on.
- **Handles open apps.** It asks before quitting a browser, Claude, your editors or other apps. Scheduled runs skip any app that's open instead of quitting it.
- **Weekly schedule.** One command sets it to run every week, using a macOS LaunchAgent.
- **Guard rails.** It refuses to delete anything outside your home folder and never follows `..` in a path.
- **Logging and notifications.** Each run is logged to `~/Library/Logs/mac-cleanup.log`, and macOS shows a notification with how much it freed.
- **No dependencies.** It runs on the bash 3.2 that comes with macOS.

## Install

```bash
git clone https://github.com/<you>/mac-cleanup.git ~/.local/share/mac-cleanup
cd ~/.local/share/mac-cleanup
chmod +x mac-cleanup.sh

# optional: a short alias
echo "alias cleanup=\"$PWD/mac-cleanup.sh\"" >> ~/.zshrc && source ~/.zshrc
```

Avoid cloning into `~/Desktop`, `~/Documents` or `~/Downloads` if you plan to schedule it: macOS blocks launchd from reading those folders, so the weekly run fails silently.

The first time it runs, it copies `mac-cleanup.conf` to `~/.config/mac-cleanup/mac-cleanup.conf`. **Edit that copy**, so your settings stay out of the repo and survive a `git pull`.

## Usage

| Command | What it does |
|---|---|
| `cleanup --dry-run` | Show what would be removed, without deleting anything. Start here. |
| `cleanup` | Run all enabled tasks. It asks before quitting apps. |
| `cleanup --yes` | Run without prompts. Apps are quit if `QUIT_APPS` allows it. |
| `cleanup --only browser_cache,xcode` | Run only the tasks you name, whatever the config says. |
| `cleanup --list` | List tasks and whether each is enabled. |
| `cleanup --report` | Show the current size of everything it manages. |
| `cleanup --schedule` | Run automatically every week (Sunday 11:00 by default). |
| `cleanup --unschedule` | Remove the schedule. |
| `cleanup --config FILE` | Use a different config file. |

## Tasks

| Task | Default | What it removes | Side effects |
|---|---|---|---|
| `browser_cache` | ✅ on | Cache, Code Cache, GPU and shader caches and service-worker caches in every profile of Chrome, Brave, Edge, Arc, Vivaldi, Opera and Chromium (pick with `BROWSERS`), plus each browser's `~/Library/Caches` folder. Formerly `chrome_cache`; old configs still work | Sites load slightly slower once |
| `chrome_ai_model` | ✅ on | The Gemini Nano model (`OptGuideOnDeviceModel/weights.bin`, about 4 GB). It also sets the `GenAILocalFoundationalModelSettings=1` policy so the model isn't downloaded again | Chrome's on-device AI features are turned off, and Chrome shows "Managed by your organization" |
| `claude_cache` | ✅ on | Claude desktop caches. **It never touches `vm_bundles`** (the Cowork VM) | None |
| `editor_cache` | ✅ on | VS Code and Cursor caches and logs. Settings, extensions and workspace history are kept | None |
| `xcode` | ✅ on | `DerivedData`, simulator caches, `iOS DeviceSupport`, and simulators for iOS versions that are no longer installed | The next build is a full build |
| `android` | ✅ on | Old NDK versions (it keeps the newest `ANDROID_NDK_KEEP`, plus any pinned versions) and `~/.gradle/caches` | Gradle downloads dependencies again on the next build |
| `package_caches` | ✅ on | `pnpm store prune`, plus clearing the npm, yarn, pip, conda and Homebrew caches | Packages download again when a project needs them |
| `app_cache` | ✅ on | The same cache folders for Slack, Discord, Teams, Notion, Figma, Postman, Linear, Obsidian, GitHub Desktop and Spotify (pick with `APPS`) | None. Logins and data are kept |
| `dev_caches` | ✅ on | Download caches for Bun, Deno, Yarn Berry, uv, Poetry (not its virtualenvs), Go build, Cargo, Composer, CocoaPods, SwiftPM, Carthage, Expo, Electron, node-gyp, Prisma and Corepack (pick with `DEV_CACHES`). `playwright`, `puppeteer` and `cypress` can be added, but you must reinstall their browsers afterwards | Downloaded again on demand |
| `user_logs` | ✅ on | Files in `~/Library/Logs` older than `LOG_MAX_AGE_DAYS` | None |
| `chrome_webstorage` | ⛔ off | Chrome site data (IndexedDB and offline storage) in each profile | **May sign you out of web apps** (WhatsApp Web, Slack and similar) |
| `whatsapp_media` | ⛔ off | WhatsApp media older than `WHATSAPP_MEDIA_MAX_AGE_DAYS` | Old media is removed from this Mac. It needs Full Disk Access |
| `zoom_cache` | ⛔ off | Zoom's auto-updater and webview caches | None. Recordings are kept |
| `docker_prune` | ⛔ off | `docker system prune -a`, and optionally `--volumes` | Unused images have to be pulled again |
| `extra_paths` | ⛔ off | Any folders you list in `EXTRA_PATHS` | Whatever those folders hold |

## Configuration

Everything lives in `~/.config/mac-cleanup/mac-cleanup.conf`:

```bash
DRY_RUN=false            # true = never delete, only report
QUIT_APPS=ask            # ask | yes | no
NOTIFY=true              # macOS notification when a run finishes

ENABLE_BROWSER_CACHE=true
BROWSERS="chrome brave edge arc vivaldi opera chromium"
CHROME_PROFILES_ONLY=""  # e.g. "Default,Profile 6"; empty means all profiles

ENABLE_ANDROID=true
ANDROID_NDK_KEEP=1       # keep the newest N NDK versions
ANDROID_NDK_PIN=""       # always keep these, e.g. "26.1.10909125"

ENABLE_EXTRA_PATHS=true
EXTRA_PATHS=(
  "$HOME/Library/Caches/SomeApp"
)
```

See [`mac-cleanup.conf`](mac-cleanup.conf) for every option.

## What it never touches

- Chrome logins, cookies, passwords, history, bookmarks and extensions
- Claude's Cowork VM (`~/Library/Application Support/Claude/vm_bundles`)
- Editor settings, extensions and workspace history
- Docker volumes, unless you set `DOCKER_PRUNE_VOLUMES=true`
- Anything outside your home folder

## Scheduling

```bash
cleanup --schedule
```

This creates `~/Library/LaunchAgents/com.user.mac-cleanup.plist`, which runs every Sunday at 11:00. To change the time, set `SCHEDULE_WEEKDAY`, `SCHEDULE_HOUR` and `SCHEDULE_MINUTE` in the config and run `cleanup --schedule` again.

On scheduled runs, any app that's open is skipped rather than quit. Output goes to `~/Library/Logs/mac-cleanup.out.log`.

## Troubleshooting

- **"Operation not permitted":** macOS protects other apps' containers, such as WhatsApp. Turn on Full Disk Access for Terminal (System Settings → Privacy & Security → Full Disk Access) and restart Terminal.
- **A scheduled run can't find `pnpm`, `npm` or `conda`:** launchd uses a minimal `PATH`. Add the right folders to `EXTRA_PATH` in the config, or set `CONDA_BIN`. If `npm` isn't on the `PATH`, the script loads nvm automatically.
- **The scheduled run never does anything:** check `~/Library/Logs/mac-cleanup.out.log`. If it says "Operation not permitted", the script is in a protected folder (Desktop, Documents, Downloads). Move the repo and run `cleanup --schedule` again.
- **Colima's disk file didn't shrink after a Docker prune:** the disk image (`~/.colima`) only shrinks after `colima stop && colima start`. To reclaim all of it, run `colima delete`.
- **System Settings still shows the old size:** the Storage panel takes a few minutes to update, and restarting your Mac clears swap and temporary files too.

## Uninstall

```bash
cleanup --unschedule
rm -rf ~/.config/mac-cleanup ~/Library/Logs/mac-cleanup*.log
```

Then delete the repo folder.

## Disclaimer

The script deletes files. Run `--dry-run` first, and review the config before turning on any task that's off by default. Use it at your own risk.
