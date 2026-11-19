# ChipDeck

An always-on-top overlay for Windows with a tool strip and a system-tray menu.
The project is split into a **host** and **features**:

```
ChipDeck/
  host/
    chipdeck.ps1       window, tool strip, tray, feature loader, generic renderers
    settings.ps1       preferences, feature toggles and the settings window
    launch.ps1         starts the host hidden
    chipdeck.cmd       double-clickable launcher
  features/
    dsh-agents/        DSH chats and approvals (script feature + local bridge)
    zapret/            one Windows service: status, start/stop, autostart (service feature)
    clock/             example command feature, disabled by default
  docs/
    FEATURES.md        feature contract and examples
```

The host knows nothing about DSH or zapret. It discovers every directory under
`features/` that has a `feature.json` and renders it according to its `kind`:
`service`, `commands`, or `script`. Adding a feature means adding a directory.

## Use

```bat
chipdeck               :: last used feature
chipdeck zapret        :: open on a specific feature
```

The window is frameless, always-on-top, drag it by the header, resize it from
the edges. Its ✕ hides it to the tray; the tray icon brings it back on a double
click (Windows 11 keeps new icons in the overflow «^» — pin it to the taskbar).
The ⚙ next to the ✕ opens the settings page (features, opacity, always-on-top).

The tray menu has: show/hide, the current feature, a **Фичи** submenu, one
start/stop/restart group per `service` feature, and **Выход** (which also lets
features clean up — the DSH agents feature stops its bridge).

## Settings

The gear in the title bar (**⚙**) or the tray item (**⚙ Настройки…**) opens the
same settings page:

- **Features** — a checkbox per discovered feature; turn any of them on or off
  without editing `feature.json` (the `clock` example is off by default but can
  be switched on here);
- **Opacity** — 30–100 %, applied to the overlay immediately;
- **Поверх всех окон** — keep the window above other applications.

Preferences live in `%LOCALAPPDATA%\chipdeck\settings.json`. Per-feature
overrides from this page take precedence over `enabled` in `feature.json`, so
editing a descriptor does not fight the settings page.

## Features

| Feature | Kind | What it does |
|---|---|---|
| `dsh-agents` | script | Running DSH sessions and pending approvals with allow/reject; a local bridge carries state from the DSH page; adds an "Открыть DSH" tray entry. |
| `zapret` | service | Status of the `zapret` service, start/stop/restart, autostart toggle, open its folder, folder tray entry. |
| `clock` | commands | Example: a status command with a timer and two action buttons (disabled). |

Chips show each feature's `icon` (PNG) or a `glyph` fallback. Drag a chip to
reorder features — the order is saved in `order.json`. Editing anything under
`features/` reloads it in the running host: enable a feature by flipping
`enabled` to `true`, no restart needed.

`dsh-agents` needs the DSH client plugin
(`plugins/agent-overlay`) installed in the DSH profile and the DSH page open.
The bridge runs on `127.0.0.1:5199`, in the feature's runtime directory. If an
older overlay instance still owns that port, the footer says so — exit the old
instance and reopen.

## Requirements

- Windows with Windows PowerShell 5.1 (WPF and WinForms are used).
- Node.js for the `dsh-agents` bridge (it starts lazily).
- Starting and stopping services needs the one-time grant in
  `features/zapret/grant-service-control.ps1`.

## Runtime files

`%LOCALAPPDATA%\chipdeck` holds `window.json`, `focus.flag`, `host-errors.log`,
and one subdirectory per feature. `CHIPDECK_DIR` moves the root.

## Quick start (from the repository)

```bat
git clone https://github.com/McMorsh/ChipDeck.git chipdeck
cd chipdeck
setup.cmd
```

The first run detects the DSH profile, asks whether to enable the **DSH agents**
feature, links `dsh-plugin` into that profile (junction, no pnpm), stores the
choice in `settings.json` and starts the overlay. Restart DSH afterwards so it
loads the plugin.

Flags: `-WithDsh`, `-WithoutDsh` (skip DSH entirely), `-NoLaunch`, `-NoPause`,
`-Install` (copy to `%LOCALAPPDATA%\Programs\ChipDeck` with shortcuts).
Without a DSH profile the overlay still works; the agents feature stays off.

## Install

Run `install.cmd` (or `install.ps1`) from this folder. It copies ChipDeck to
`%LOCALAPPDATA%\Programs\ChipDeck`, creates Start Menu and startup shortcuts,
and when DSH is present installs the bundled `dsh-plugin` into the DSH profile
and adds `@local/dsh-agent-overlay` to `dsh.profile.bundles`.

Close DSH before running the installer: the running DSH holds the profile lock
and pnpm cannot update it.

Options: `-InstallDir <path>`, `-NoAutostart`, `-SkipDsh`, `-NoLaunch`,
`-DshDryRun` (print the DSH command without running it), `-DshCommand <path>`.

Uninstall with `uninstall.cmd`; add `-RemoveDshPlugin` to disable the plugin in
DSH and `-RemoveSettings` to delete `%LOCALAPPDATA%\chipdeck`.

## Docs

- [docs/FEATURES.md](docs/FEATURES.md) — the feature contract, host API, examples.
