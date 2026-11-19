# ChipDeck features

A feature is a directory under `features/` with a `feature.json`. The host
discovers them at startup, sorts them by the saved chip order (then `order`,
then `title`), and watches the directory: adding, removing, or editing a
feature reloads it in the running host — no restart.

## Common fields

| Field | Type | Meaning |
|---|---|---|
| `id` | string | Unique id; runtime directory name and tray identity. |
| `title` | string | Chip label. |
| `order` | number | Fallback strip position, ascending; default `100`. |
| `kind` | string | `service`, `commands`, or `script`. |
| `enabled` | boolean | `false` hides the feature; default `true`. |
| `entry` | string | Script feature entry file; default `feature.ps1`. |
| `icon` | string | PNG path relative to the feature directory, shown in the chip. |
| `glyph` | string | Fallback single character or emoji when there is no icon. |
| `tray` | array | Declarative tray entries: `[{ "label": "...", "command": "..." }]`. |

## Settings

The tray gear opens a settings page with one checkbox per feature, an opacity
slider (30–100 %) and a “topmost” switch. It is backed by
`%LOCALAPPDATA%\chipdeck\settings.json`:

```json
{ "opacity": 0.9, "topmost": true, "enabled": { "clock": true } }
```

`enabled` stores per-feature overrides: a value here wins over `enabled` in
`feature.json`, which is only the default. `opacity` multiplies the whole
window; `topmost` also drives `Window.Topmost`. The file is read at startup and
rewritten whenever a setting changes.
## Chip order

Drag a chip along the strip to reorder features. The order is saved to
`%LOCALAPPDATA%\chipdeck\order.json` (a plain array of ids) and survives
restarts; features added later are appended after the saved ones unless their
`order` places them differently. A click without dragging selects the feature.

## Hot reload

The host fingerprints every file under `features/` and re-reads them roughly
once a second. On a change it:

- disposes and unloads script features whose descriptor or entry changed, and
  removes those that disappeared;
- loads new script features and calls their `Initialize-Feature`;
- rebuilds chips and the tray menu, keeping the active feature when it still
  exists.

Editing a `feature.json` is enough to enable or disable a feature live.

## `kind: "service"`

Generic: controls one Windows service.

```json
{
  "id": "service-example",
  "title": "Служба",
  "order": 20,
  "kind": "service",
  "service": "MyService",
  "autostart": true,
  "openFolder": true,
  "icon": "icon.png"
}
```

`service` is the exact service name; `autostart` shows the start-type toggle
(needs UAC); `openFolder` derives the directory from the service `ImagePath`.
Start/stop may need a per-service grant; `features/zapret/grant-service-control.ps1`
shows one for the zapret service.

## `kind: "commands"`

Generic: a status command with a refresh timer plus action buttons that show
their output.

```json
{
  "id": "clock",
  "title": "Часы",
  "kind": "commands",
  "status": "Get-Date -Format 'dd.MM.yyyy HH:mm:ss'",
  "refreshSeconds": 5,
  "actions": [
    { "label": "Открыть загрузки", "command": "Start-Process $env:USERPROFILE\\Downloads" }
  ]
}
```

`status` runs in a child PowerShell (10 s timeout) and renders as monospace
text; actions run with a 30 s timeout and their output appears under «ВЫВОД».
A `feature.json` is as powerful as a script you wrote yourself: only add
trusted ones.

## `kind: "script"`

The host loads the entry file as a **PowerShell module** and calls its hooks.
The module keeps its own scope, so its helper functions and `$script:`
variables survive between calls; handlers created with `GetNewClosure()` work.

The file starts with:

```powershell
param($Api, $FeatureDir)
```

and defines any of:

| Function | When |
|---|---|
| `Initialize-Feature($Api)` | once, at host start (and after a reload) |
| `Enter-Feature($Api)` | whenever the feature is selected |
| `Update-Feature($Api)` | about every 400 ms while selected |
| `Dispose-Feature($Api)` | when unloaded or on host exit |

Build the view by clearing the panel and adding host widgets. Handlers must
capture locals with `.GetNewClosure()` — module functions stay resolvable, but
locals do not survive on their own.

### Host API (`$Api`)

| Member | Meaning |
|---|---|
| `Feature` | The descriptor object (`Id`, `Title`, `Kind`, `Dir`, …). |
| `RuntimeDir` | Per-feature runtime directory, created for you. |
| `HostDir` | The host directory. |
| `Panel` | The `StackPanel` to fill. |
| `Clear` | Empties the panel. |
| `NewSection(text)` | Section caption. |
| `NewRow(tone, title, meta, buttons)` | Card row; `tone` is `run`, `warn`, or `idle`. |
| `NewButton(style, text, onClick)` | Compact button; `style` is `AllowButton`, `RejectButton`, or `GhostButton`. |
| `NewFullButton(style, text, onClick)` | Full-width button. |
| `GetResource(key)` | Host style by key (`MutedText`, `MonoText`, `PillButton`, …). |
| `SetSummary(text)` | Header subtitle. |
| `SetFooter(text)` | Footer line. |
| `ShowBalloon(title, text)` | Tray balloon. |
| `RunCommand(command, timeoutSeconds)` | Runs PowerShell in a child process, returns text. |
| `WriteJson(path, text)` | Atomic file write. |
| `AddTrayItem(label, onClick)` | Adds an entry under this feature's tray submenu. |

### Skeleton

```powershell
param($Api, $FeatureDir)

$script:Api = $Api
$script:Dir = $Api.RuntimeDir

function Render {
  & $script:Api.Clear
  & $script:Api.SetSummary 'привет'
  $value = 'мир'
  $button = & $script:Api.NewButton 'AllowButton' 'Нажми' {
    & $script:Api.ShowBalloon 'Пример' $value
  }.GetNewClosure()
  & $script:Api.NewRow 'run' 'Пример' 'кнопка ниже' @($button) | Out-Null
}

function Initialize-Feature {
  param($Api)
  $script:Api = $Api
  & $Api.AddTrayItem 'Проверить' { & $Api.ShowBalloon 'Пример' 'готово' }
}

function Enter-Feature { param($Api) $script:Api = $Api; & $Api.Clear; Render }
function Update-Feature { param($Api) }
function Dispose-Feature { param($Api) }
```

## The `zapret` feature

A script feature, so it works even when the Windows service is not installed
yet. It finds the distribution in this order: the path saved in
`RuntimeDir\zapret-path.txt`, the service `ImagePath`, then `zapret*`
directories in `C:\`, `D:\`, Downloads, Desktop, Documents, the profile root
and `%LOCALAPPDATA%\Programs`. A candidate survives only if it contains
`bin\winws.exe` or `winws.exe`; the optional `service` field of `feature.json`
names the service (default `zapret`).

The view reports one of four states: service running, service stopped, no
service but a bare `winws.exe` process, or nothing found. Buttons depend on the
state: start/stop/restart and the autostart toggle need the service; **Установить
службу…** runs the distribution's `service.bat` elevated so the user picks a
strategy (`Install Service` in its menu); **Указать папку zapret…** overrides
discovery through a folder picker and persists the choice. A bare `winws.exe`
started by `general.bat` is visible but not controllable — without a service
there is nothing for the overlay to start or stop.

## The `dsh-agents` feature

A script feature that speaks to the DSH page through `bridge.js` in its own
directory. The bridge listens on `127.0.0.1:5199` and exposes `/health`,
`/state`, `/commands`, `/focus`, `/shutdown`; it writes into the feature's
runtime directory. The feature starts the bridge lazily, renders the pushed
model, sends approve/reject/open commands back, stops the bridge on exit, and
contributes an "Открыть DSH" tray entry.

The matching DSH client plugin lives in `plugins/agent-overlay` and pushes
`{running, waiting, origin}` roughly once a second.

## Testing

| Variable | Effect |
|---|---|
| `CHIPDECK_FEATURES` | Use another features root. |
| `CHIPDECK_FEATURE` | Initial feature id (`chipdeck <id>` sets it). |
| `CHIPDECK_DIR` | Another runtime root (order, bounds, feature runtimes). |
| `CHIPDECK_MUTEX_SUFFIX` | Separate single-instance mutex for a test copy. |
| `CHIPDECK_TEST_EXIT_MS` | Close the window after N ms. |
| `CHIPDECK_SELFTEST` | Switch through every feature once, then log the result. |
| `CHIPDECK_SELFTEST_CLICK` | Also run the chip-click path programmatically. |
| `CHIPDECK_SELFTEST_DRAG` | Also reorder a chip and persist `order.json`. |
| `CHIPDECK_DEBUG` | Log click/drag/switch events to `host-errors.log`. |
