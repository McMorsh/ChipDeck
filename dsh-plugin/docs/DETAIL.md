# Agent overlay

A frame-wide launcher pill and an always-on-top panel for the chats that are
doing work right now.

## What it shows

- **Needs a decision** — every pending approval of this Client: the session
  title, the tool that asked, and the reason it gave. **Allow** answers the same
  request the composer shows, **Reject** refuses it; the first answer settles the
  request everywhere.
- **Running chats** — sessions whose Agent is running, with a pulsing dot and an
  **Open chat** action that brings that session to the main view.

## Native window outside the browser

The companion project in `dsh-overlay` (a host plus features) renders the same panel as its own
always-on-top window, independent of the browser window. Start it with
`dsh-overlay`: it opens on any monitor, is dragged by its header, and shows
running chats and pending approvals with **Allow** / **Reject** buttons. Its
system-tray menu also shows and hides the window, opens any tool, and starts,
stops, or restarts the `zapret` service. The window is a shell with a tool
strip: the agents view, a service view per Windows service, and command tools
described by `tools/<id>/tool.json`. While that host runs, the pill turns into a "bring the
native window to front" button; without it the pill opens the
Picture-in-Picture panel (or the in-page panel when the browser has no
floating-window support).

## How to use it

Click the **Overlay** pill at the bottom right corner of the page. The panel
opens as a floating window that stays above other applications; move it by its
own title bar and resize it from its edges. Closing that window leaves the pill
in place, and the counts update live while it is open.

## Limitations

- The floating window is the browser's Document Picture-in-Picture window: it
  needs a Chromium-based browser (Chrome or Edge 116 or newer) and the DSH page
  to stay open. Without support the pill opens the same panel inside the page.
- The panel lists the sessions this Client knows: detached sessions without a
  live Agent appear only while they still have a pending request.
- Only approvals of this Client's Host are shown; another Host's requests appear
  in that Host's page.
