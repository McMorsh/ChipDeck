/**
 * Agent overlay, browser half.
 *
 * A launcher pill in the frame-wide `shell.overlay` layer opens an
 * always-on-top panel through the Document Picture-in-Picture API. The panel
 * lists the chats that are running right now and the agent actions waiting for
 * a decision, with Allow / Reject buttons that answer the pending approval
 * directly.
 *
 * Data comes from the shipped Client services: `sessions.list` (identity and
 * display title), `uiSession.sessionStatus` (running flag and the effective
 * pending interaction) and `uiSession.pendingInteractions` (the answerable
 * PendingApproval instances). No Host half is needed.
 */
window.__ModuleLoader__.load({
  id: '@local/dsh-agent-overlay',
  factory(require) {
    const React = require('react')
    const { createRoot } = require('react-dom/client')
    const h = React.createElement

    const NS = 'agentOverlay'
    const PILL_CLASS = 'dshao-pill'

    const CSS = `
.dshao-pill{position:fixed;left:16px;bottom:88px;z-index:70;display:inline-flex;align-items:center;gap:8px;
  padding:7px 12px;border-radius:999px;border:1px solid var(--dsw-alias-border-l1);
  background:var(--dsw-alias-bg-overlay);color:var(--dsw-alias-label-primary);
  font:600 12px/1.25 system-ui,-apple-system,"Segoe UI",sans-serif;box-shadow:0 8px 28px rgba(0,0,0,.22);
  cursor:pointer;pointer-events:auto;transition:border-color .15s ease,transform .15s ease}
.dshao-pill:hover{border-color:var(--dsw-alias-border-l2)}
.dshao-pill:active{transform:scale(.98)}
.dshao-dot{width:8px;height:8px;border-radius:50%;background:var(--dsw-alias-state-idle-primary);flex:none}
.dshao-dot[data-busy="true"]{background:var(--dsw-alias-state-success-primary);animation:dshao-pulse 1.2s ease-in-out infinite}
@keyframes dshao-pulse{0%,100%{opacity:.35}50%{opacity:1}}
.dshao-badge{min-width:18px;height:18px;padding:0 5px;border-radius:9px;display:inline-flex;align-items:center;
  justify-content:center;font-size:11px;font-variant-numeric:tabular-nums;
  background:var(--dsw-alias-bg-layer-2);color:var(--dsw-alias-label-secondary)}
.dshao-badge[data-tone="warn"]{background:var(--dsw-alias-state-warn-primary);color:#1b1500}
.dshao-panel{position:fixed;left:16px;bottom:136px;z-index:70;width:340px;max-height:62vh;overflow:auto;
  border-radius:14px;border:1px solid var(--dsw-alias-border-l1);background:var(--dsw-alias-bg-overlay);
  box-shadow:0 18px 48px rgba(0,0,0,.28);pointer-events:auto}
.dshao-root{display:flex;flex-direction:column;height:100%;box-sizing:border-box;
  background:var(--dsw-alias-bg-base);color:var(--dsw-alias-label-primary);
  font:500 12.5px/1.35 system-ui,-apple-system,"Segoe UI",sans-serif}
.dshao-root[data-mode="pip"]{height:100vh}
.dshao-head{display:flex;align-items:center;gap:8px;padding:10px 12px;border-bottom:1px solid var(--dsw-alias-border-l1);
  background:var(--dsw-alias-bg-layer-1);flex:none}
.dshao-head-title{font-weight:700;font-size:12.5px;letter-spacing:.01em}
.dshao-head-meta{margin-left:auto;color:var(--dsw-alias-label-secondary);font-size:11px}
.dshao-body{padding:8px;display:flex;flex-direction:column;gap:8px;overflow:auto;flex:1;min-height:0}
.dshao-section{display:flex;flex-direction:column;gap:6px}
.dshao-section-title{font-size:10.5px;font-weight:700;letter-spacing:.06em;text-transform:uppercase;
  color:var(--dsw-alias-label-secondary);padding:2px 4px}
.dshao-row{display:flex;align-items:flex-start;gap:8px;padding:8px;border-radius:10px;
  border:1px solid var(--dsw-alias-border-l1);background:var(--dsw-alias-bg-layer-1)}
.dshao-row[data-tone="warn"]{border-color:var(--dsw-alias-state-warn-primary)}
.dshao-state{width:8px;height:8px;border-radius:50%;margin-top:4px;flex:none;background:var(--dsw-alias-state-success-primary)}
.dshao-state[data-tone="warn"]{background:var(--dsw-alias-state-warn-primary)}
.dshao-state[data-tone="idle"]{background:var(--dsw-alias-state-idle-primary)}
.dshao-state[data-busy="true"]{animation:dshao-pulse 1.2s ease-in-out infinite}
.dshao-main{display:flex;flex-direction:column;gap:3px;min-width:0;flex:1}
.dshao-title{all:unset;cursor:pointer;font-weight:600;font-size:12.5px;color:var(--dsw-alias-label-primary);
  overflow:hidden;text-overflow:ellipsis;white-space:nowrap}
.dshao-title:hover{text-decoration:underline;text-underline-offset:2px}
.dshao-meta{color:var(--dsw-alias-label-secondary);font-size:11px;display:flex;flex-direction:column;gap:2px;
  overflow:hidden}
.dshao-meta span{overflow:hidden;text-overflow:ellipsis;white-space:nowrap}
.dshao-actions{display:flex;flex-direction:column;gap:4px;flex:none}
.dshao-btn{all:unset;box-sizing:border-box;cursor:pointer;text-align:center;padding:4px 9px;border-radius:7px;
  font:600 11px/1.3 system-ui,-apple-system,"Segoe UI",sans-serif;
  border:1px solid var(--dsw-alias-border-l1);background:var(--dsw-alias-bg-layer-2);color:var(--dsw-alias-label-primary)}
.dshao-btn:hover{border-color:var(--dsw-alias-border-l2)}
.dshao-btn[disabled]{opacity:.45;cursor:default}
.dshao-btn--allow{background:var(--dsw-alias-brand-primary);border-color:transparent;color:#fff}
.dshao-btn--allow:hover{filter:brightness(1.08)}
.dshao-btn--reject{color:var(--dsw-alias-state-error-primary);border-color:var(--dsw-alias-border-l1)}
.dshao-empty{padding:18px 12px;text-align:center;color:var(--dsw-alias-label-secondary);font-size:11.5px}
.dshao-crash{position:fixed;right:16px;bottom:16px;z-index:80;max-width:440px;padding:8px 12px;border-radius:8px;
  background:#7a1010;color:#fff;font:11px/1.4 ui-monospace,Consolas,monospace;pointer-events:auto;white-space:pre-wrap}
`

    /* Module-scope Picture-in-Picture handle: one panel per page, shared by all
     * slot entries of this bundle. */
    let pipWindow = null
    let pipRoot = null
    const pipWatchers = new Set()

    /** Notify launcher entries that the panel opened or closed. */
    const notifyPip = () => {
      for (const watcher of [...pipWatchers]) {
        try { watcher() } catch { /* a listener must not break the others */ }
      }
    }
    const subscribePip = (watcher) => {
      pipWatchers.add(watcher)
      return () => { pipWatchers.delete(watcher) }
    }
    const pipIsOpen = () => pipWindow !== null

    /* Native overlay host bridge: the page pushes state and polls commands over
     * loopback HTTP, so an always-on-top window outside the browser can show the
     * same chats and answer the same approvals. */
    const BRIDGE = 'http://127.0.0.1:5199'
    let bridgeAlive = false
    const bridgeWatchers = new Set()
    const notifyBridge = () => {
      for (const watcher of [...bridgeWatchers]) {
        try { watcher() } catch { /* one listener must not break the others */ }
      }
    }
    const subscribeBridge = (watcher) => {
      bridgeWatchers.add(watcher)
      return () => { bridgeWatchers.delete(watcher) }
    }
    const bridgeIsAlive = () => bridgeAlive

    /** Read one observable synchronously for the bridge payload. */
    function snapshotOf(observable) {
      if (observable === undefined || observable === null || typeof observable.getSnapshot !== 'function') return undefined
      try { return observable.getSnapshot() } catch { return undefined }
    }

    /** Serialize the current model for the native host. */
    function bridgePayload(api) {
      const sessionsService = api.get('sessions')
      const uiSession = api.get('uiSession')
      const rows = rowsOf(
        snapshotOf(sessionsService === undefined ? undefined : sessionsService.list),
        snapshotOf(uiSession === undefined ? undefined : uiSession.sessionStatus),
        snapshotOf(uiSession === undefined ? undefined : uiSession.pendingInteractions),
      )
      return {
        type: 'state',
        at: Date.now(),
        origin: typeof location === 'undefined' ? '' : location.href,
        running: rows
          .filter(row => row.waiting === undefined || row.waiting === null)
          .map(row => ({ sessionId: String(row.id), title: row.title })),
        waiting: rows
          .filter(row => row.waiting !== undefined && row.waiting !== null)
          .map(row => ({
            key: String(row.waiting.key ?? ''),
            kind: String(row.waiting.kind ?? ''),
            sessionId: String(row.id),
            title: row.title,
            tool: typeof row.waiting.toolName === 'string' ? row.waiting.toolName : '',
            reason: reasonOf(row.waiting, 'en'),
            answerable: row.waiting.answerable !== false,
            // A question carries the option batch the native panel may answer;
            // approvals carry no questions and stay on the allow/reject path.
            questions: Array.isArray(row.waiting.questions)
              ? row.waiting.questions.map(question => ({
                  id: String(question.id),
                  question: String(question.question ?? ''),
                  header: typeof question.header === 'string' ? question.header : '',
                  detail: typeof question.detail === 'string' ? question.detail : '',
                  multiSelect: question.multiSelect === true,
                  options: Array.isArray(question.options)
                    ? question.options.map(option => ({
                        label: String(option.label),
                        description: typeof option.description === 'string' ? option.description : '',
                      }))
                    : [],
                  intent: question.intent === undefined || question.intent === null
                    ? null
                    : {
                        kind: String(question.intent.kind ?? ''),
                        approve: typeof question.intent.approve === 'string' ? question.intent.approve : '',
                        reject: typeof question.intent.reject === 'string' ? question.intent.reject : '',
                        always: typeof question.intent.always === 'string' ? question.intent.always : '',
                      },
                }))
              : [],
          })),
      }
    }

    /** Find the live pending interaction by its stable key. */
    function interactionByKey(api, key) {
      const uiSession = api.get('uiSession')
      const pending = snapshotOf(uiSession === undefined ? undefined : uiSession.pendingInteractions)
      let found
      if (pending !== undefined && pending !== null && typeof pending.forEach === 'function') {
        pending.forEach((interaction) => {
          if (String(interaction.key ?? '') === key) found = interaction
        })
        if (found !== undefined) return found
      }
      // The pending map is filled by the mounted card; a blocking question can
      // sit only in the per-session status, so search that projection too.
      const sessionsService = api.get('sessions')
      const list = snapshotOf(sessionsService === undefined ? undefined : sessionsService.list)
      const status = snapshotOf(uiSession === undefined ? undefined : uiSession.sessionStatus)
      if (list === undefined || status === undefined || typeof status.get !== 'function') return undefined
      const ids = Array.isArray(list.ids) ? list.ids : Object.keys((list && list.byId) || {})
      for (const id of ids) {
        const state = status.get(id)
        const candidate = state === undefined || state === null ? undefined : state.pendingInteraction
        if (candidate !== undefined && candidate !== null && String(candidate.key ?? '') === key) return candidate
      }
      return found
    }

    /** Poll and execute native-host commands. */
    async function drainCommands(api) {
      const response = await fetch(`${BRIDGE}/commands`, { signal: AbortSignal.timeout(1500), cache: 'no-store' })
      if (!response.ok) return
      const commands = await response.json()
      if (!Array.isArray(commands)) return
      for (const command of commands) {
        if (command === null || typeof command !== 'object') continue
        if (command.type === 'answer' && typeof command.key === 'string' && (command.decision === 'allowed-once' || command.decision === 'rejected')) {
          const interaction = interactionByKey(api, command.key)
          // Only approvals accept 'allowed-once'/'rejected'; a question takes a
          // structured answer batch from the separate command below.
          if (interaction !== undefined && interaction.kind === 'approval' && interaction.answerable !== false) api.answer(interaction, command.decision)
        } else if (command.type === 'answer-question' && typeof command.key === 'string' && Array.isArray(command.answers)) {
          const interaction = interactionByKey(api, command.key)
          if (interaction !== undefined && typeof interaction.answer === 'function' && interaction.kind !== 'approval') {
            try {
              const result = interaction.answer({ answers: command.answers })
              if (result !== undefined && result !== null && typeof result.catch === 'function') result.catch(() => {})
            } catch { /* the request settled between render and click */ }
          }
        } else if (command.type === 'open' && typeof command.sessionId === 'string') {
          api.open(command.sessionId)
        }
      }
    }

    /** Keep the native host fed while it is running; the overlay falls back to the panel otherwise. */
    function startBridge(api, t) {
      let stopped = false
      let pushed = 0
      const ping = async () => {
        try {
          const response = await fetch(`${BRIDGE}/health`, { signal: AbortSignal.timeout(1200), cache: 'no-store' })
          const next = response.ok
          if (next !== bridgeAlive) { bridgeAlive = next; notifyBridge() }
        } catch {
          if (bridgeAlive) { bridgeAlive = false; notifyBridge() }
        }
      }
      const push = async () => {
        if (!bridgeAlive || stopped) return
        try {
          await fetch(`${BRIDGE}/state`, {
            method: 'POST',
            headers: { 'content-type': 'application/json' },
            body: JSON.stringify(bridgePayload(api)),
            signal: AbortSignal.timeout(1500),
          })
        } catch { /* the next ping flips the state */ }
      }
      const drain = async () => {
        if (!bridgeAlive || stopped) return
        try { await drainCommands(api) } catch { /* transient */ }
      }
      void ping()
      const pingTimer = setInterval(() => { void ping() }, 5000)
      const pushTimer = setInterval(() => { void push() }, 900)
      const drainTimer = setInterval(() => { void drain() }, 700)
      // Push immediately on model changes as well, so approvals do not wait for the heartbeat.
      const sessionsService = api.get('sessions')
      const uiSession = api.get('uiSession')
      const watched = [
        sessionsService === undefined ? undefined : sessionsService.list,
        uiSession === undefined ? undefined : uiSession.sessionStatus,
        uiSession === undefined ? undefined : uiSession.pendingInteractions,
      ].filter(observable => observable !== undefined && observable !== null && typeof observable.subscribe === 'function')
      const unsubscribes = watched.map(observable => observable.subscribe(() => {
        pushed += 1
        if (pushed % 1 === 0) void push()
      }))
      return () => {
        stopped = true
        clearInterval(pingTimer)
        clearInterval(pushTimer)
        clearInterval(drainTimer)
        for (const unsubscribe of unsubscribes) { try { unsubscribe() } catch { /* disposed */ } }
        bridgeAlive = false
        notifyBridge()
        void t
      }
    }

    /**
     * Subscribe to a HostObservable without scanning it.
     * @param observable - observable face, absent while its service still boots.
     * @returns current snapshot.
     */
    function useSnapshot(observable) {
      const subscribe = React.useCallback((onChange) => {
        if (observable === undefined || observable === null || typeof observable.subscribe !== 'function') return () => {}
        return observable.subscribe(onChange)
      }, [observable])
      const read = React.useCallback(() => {
        if (observable === undefined || observable === null || typeof observable.getSnapshot !== 'function') return undefined
        return observable.getSnapshot()
      }, [observable])
      return React.useSyncExternalStore(subscribe, read, read)
    }

    /** Human-facing reason for an approval, in the active locale when provided. */
    function reasonOf(interaction, activeLocale) {
      if (interaction === undefined || interaction === null) return ''
      const localized = interaction.displayReason
      if (localized !== undefined && localized !== null && typeof localized === 'object') {
        return localized[activeLocale] ?? localized.en ?? ''
      }
      return typeof interaction.reason === 'string' ? interaction.reason : ''
    }

    /** Model rows: pending decisions first, then running chats. */
    function rowsOf(list, status, pending) {
      const byId = list !== undefined && list !== null && typeof list.byId === 'object' ? list.byId : {}
      const ids = list !== undefined && list !== null && Array.isArray(list.ids) ? list.ids : Object.keys(byId)
      const rows = []
      const seen = new Set()
      const add = (id, interaction) => {
        if (seen.has(id)) return
        seen.add(id)
        const summary = byId[id]
        const state = status !== undefined && status !== null && typeof status.get === 'function' ? status.get(id) : undefined
        const waiting = interaction ?? (state === undefined ? undefined : state.pendingInteraction)
        const running = (state === undefined ? undefined : state.running) ?? (summary === undefined ? false : summary.running) ?? false
        if (waiting === undefined && !running) return
        rows.push({
          id,
          title: summary !== undefined && summary !== null && typeof summary.displayTitle === 'string' ? summary.displayTitle : String(id),
          running,
          waiting,
        })
      }
      if (pending !== undefined && pending !== null && typeof pending.forEach === 'function') {
        for (const [id, interaction] of pending) add(id, interaction)
      }
      for (const id of ids) add(id, undefined)
      return rows
    }

    /** Panel body shared by the Picture-in-Picture window and the in-page fallback. */
    function Panel({ api, t, mode }) {
      const sessionsService = api.get('sessions')
      const uiSession = api.get('uiSession')
      const list = useSnapshot(sessionsService === undefined ? undefined : sessionsService.list)
      const status = useSnapshot(uiSession === undefined ? undefined : uiSession.sessionStatus)
      const pending = useSnapshot(uiSession === undefined ? undefined : uiSession.pendingInteractions)
      const localeSnapshot = useSnapshot(api.locale)
      const activeLocale = localeSnapshot !== undefined && typeof localeSnapshot.active === 'string' ? localeSnapshot.active : 'en'
      const rows = React.useMemo(() => rowsOf(list, status, pending), [list, status, pending])
      const waitingRows = rows.filter(row => row.waiting !== undefined && row.waiting !== null)
      const runningRows = rows.filter(row => row.waiting === undefined || row.waiting === null)
      const renderRow = (row) => {
        const interaction = row.waiting
        const approval = interaction !== undefined && interaction !== null && interaction.kind === 'approval' && typeof interaction.answer === 'function'
          ? interaction
          : null
        const reason = reasonOf(interaction, activeLocale)
        const tone = approval === null ? (row.running ? 'busy' : 'idle') : 'warn'
        return h('div', { className: 'dshao-row', key: String(row.id), 'data-tone': tone },
          h('span', { className: 'dshao-state', 'data-tone': tone, 'data-busy': String(row.running) }),
          h('div', { className: 'dshao-main' },
            h('button', {
              type: 'button', className: 'dshao-title', title: t('open'), onClick: () => api.open(row.id),
            }, row.title),
            h('div', { className: 'dshao-meta' },
              approval === null
                ? h('span', null, t('waitingAnswer'))
                : h('span', null, t('toolLabel', { tool: String(approval.toolName) })),
              reason === '' ? null : h('span', null, reason))),
          approval === null
            ? h('div', { className: 'dshao-actions' },
              h('button', { type: 'button', className: 'dshao-btn', onClick: () => api.open(row.id) }, t('open')))
            : h('div', { className: 'dshao-actions' },
              h('button', {
                type: 'button', className: 'dshao-btn dshao-btn--allow', disabled: !approval.answerable,
                onClick: () => api.answer(approval, 'allowed-once'),
              }, t('allow')),
              h('button', {
                type: 'button', className: 'dshao-btn dshao-btn--reject', disabled: !approval.answerable,
                onClick: () => api.answer(approval, 'rejected'),
              }, t('reject'))))
      }
      return h('div', { className: 'dshao-root', 'data-mode': mode },
        h('div', { className: 'dshao-head' },
          h('span', { className: 'dshao-dot', 'data-busy': String(runningRows.length > 0) }),
          h('span', { className: 'dshao-head-title' }, t('title')),
          h('span', { className: 'dshao-head-meta' }, t('summary', { running: runningRows.length, waiting: waitingRows.length }))),
        h('div', { className: 'dshao-body' },
          rows.length === 0
            ? h('div', { className: 'dshao-empty' }, t('empty'))
            : null,
          waitingRows.length === 0 ? null : h('div', { className: 'dshao-section' },
            h('div', { className: 'dshao-section-title' }, t('sectionWaiting')),
            ...waitingRows.map(renderRow)),
          runningRows.length === 0 ? null : h('div', { className: 'dshao-section' },
            h('div', { className: 'dshao-section-title' }, t('sectionRunning')),
            ...runningRows.map(renderRow))))
    }

    /** Open (or focus) the always-on-top panel with React rendered into its document. */
    async function openPanel(api, t) {
      const pip = typeof window === 'undefined' ? undefined : window.documentPictureInPicture
      if (pip === undefined || pip === null) return
      if (pipWindow !== null) {
        try { pipWindow.focus() } catch { /* a closed window is cleared by pagehide */ }
        return
      }
      let win
      try {
        win = await pip.requestWindow({ width: 340, height: 480 })
      } catch {
        return
      }
      for (const sheet of document.querySelectorAll('style, link[rel="stylesheet"]')) {
        try { win.document.head.appendChild(sheet.cloneNode(true)) } catch { /* cross-origin sheet */ }
      }
      for (const attribute of Array.from(document.documentElement.attributes)) {
        try { win.document.documentElement.setAttribute(attribute.name, attribute.value) } catch { /* reserved name */ }
      }
      const base = win.document.createElement('style')
      base.textContent = CSS + '\nhtml,body{margin:0;height:100%;overflow:hidden;background:var(--dsw-alias-bg-base);}'
      win.document.head.appendChild(base)
      win.document.title = t('title')
      const mount = win.document.createElement('div')
      mount.style.height = '100%'
      win.document.body.appendChild(mount)
      pipWindow = win
      pipRoot = createRoot(mount)
      pipRoot.render(h(Panel, { api, t, mode: 'pip' }))
      notifyPip()
      win.addEventListener('pagehide', () => {
        try { pipRoot?.unmount() } catch { /* already detached */ }
        pipRoot = null
        pipWindow = null
        notifyPip()
      })
    }

    /** Frame-wide launcher pill: pending count first, then running count. */
    function Launcher({ api, t }) {
      const pipOpen = React.useSyncExternalStore(subscribePip, pipIsOpen, pipIsOpen)
      const nativeAlive = React.useSyncExternalStore(subscribeBridge, bridgeIsAlive, bridgeIsAlive)
      const sessionsService = api.get('sessions')
      const uiSession = api.get('uiSession')
      const list = useSnapshot(sessionsService === undefined ? undefined : sessionsService.list)
      const status = useSnapshot(uiSession === undefined ? undefined : uiSession.sessionStatus)
      const pending = useSnapshot(uiSession === undefined ? undefined : uiSession.pendingInteractions)
      const rows = React.useMemo(() => rowsOf(list, status, pending), [list, status, pending])
      const waiting = rows.filter(row => row.waiting !== undefined && row.waiting !== null).length
      const running = rows.length - waiting
      const [fallbackOpen, setFallbackOpen] = React.useState(false)
      const supported = typeof window !== 'undefined' && window.documentPictureInPicture !== undefined
      const hint = nativeAlive ? t('launcherNativeHint') : supported ? t('launcherHint') : t('launcherUnsupported')
      return h(React.Fragment, null,
        h('style', { key: 'agent-overlay-style' }, CSS),
        h('button', {
          type: 'button',
          className: PILL_CLASS,
          title: hint,
          'aria-label': hint,
          'data-pip': String(pipOpen),
          'data-native': String(nativeAlive),
          onClick: () => {
            if (nativeAlive) {
              void fetch(`${BRIDGE}/focus`, { method: 'POST', signal: AbortSignal.timeout(1200) }).catch(() => {})
              return
            }
            if (supported) { void openPanel(api, t); return }
            setFallbackOpen(open => !open)
          },
        },
        h('span', { className: 'dshao-dot', 'data-busy': String(running > 0) }),
        h('span', null, t('launcher')),
        waiting === 0 ? null : h('span', { className: 'dshao-badge', 'data-tone': 'warn' }, String(waiting)),
        running === 0 ? null : h('span', { className: 'dshao-badge' }, String(running))),
        !supported && fallbackOpen ? h('div', { className: 'dshao-panel' }, h(Panel, { api, t, mode: 'page' })) : null)
    }

    /** Contain a render failure in this entry so the panel can report it instead of vanishing. */
    class Guard extends React.Component {
      constructor(props) {
        super(props)
        this.state = { error: null }
      }

      static getDerivedStateFromError(error) {
        return { error }
      }

      render() {
        if (this.state.error !== null) {
          const detail = this.state.error instanceof Error
            ? `${this.state.error.name}: ${this.state.error.message}\n${this.state.error.stack ?? ''}`
            : String(this.state.error)
          return h('div', { className: 'dshao-crash', role: 'alert' }, `Agent overlay failed:\n${detail}`)
        }
        return this.props.children
      }
    }

    return {
      inject: ['slots', 'locale', 'sessions', 'uiSession'],
      apply(ctx) {
        ctx.effect(() => ctx.locale.register(NS, {
          en: {
            launcher: 'Overlay',
            launcherHint: 'Open the always-on-top chat overlay',
            launcherNativeHint: 'The native overlay window is running; bring it to front',
            launcherUnsupported: 'This browser has no floating-window support; the panel opens in the page instead',
            title: 'Agent overlay',
            summary: '{running} running · {waiting} waiting',
            sectionWaiting: 'Needs a decision',
            sectionRunning: 'Running chats',
            toolLabel: 'Tool: {tool}',
            waitingAnswer: 'Waiting for an answer',
            allow: 'Allow',
            reject: 'Reject',
            open: 'Open chat',
            empty: 'Nothing is running and nothing needs a decision.',
          },
          ru: {
            launcher: 'Оверлей',
            launcherHint: 'Открыть плашку чатов поверх всех окон',
            launcherNativeHint: 'Нативное окно оверлея запущено; вывести его на передний план',
            launcherUnsupported: 'Браузер не умеет плавающее окно; панель откроется внутри страницы',
            title: 'Оверлей агента',
            summary: 'работают: {running} · ждут: {waiting}',
            sectionWaiting: 'Требуют подтверждения',
            sectionRunning: 'Работают',
            toolLabel: 'Инструмент: {tool}',
            waitingAnswer: 'Ждёт ответа',
            allow: 'Разрешить',
            reject: 'Отклонить',
            open: 'Открыть чат',
            empty: 'Сейчас никто не работает и подтверждать нечего.',
          },
        }), 'agent-overlay: dictionaries')

        const t = ctx.locale.bind(NS)
        const api = {
          get: name => (typeof ctx.get === 'function' ? ctx.get(name) : undefined),
          locale: ctx.locale,
          open: (id) => {
            const workspace = api.get('uiWorkspace')
            if (workspace !== undefined && workspace !== null && typeof workspace.openSession === 'function') {
              workspace.openSession(id)
            }
          },
          answer: (interaction, decision) => {
            try {
              const result = interaction.answer(decision)
              if (result !== undefined && result !== null && typeof result.catch === 'function') result.catch(() => {})
            } catch { /* the request settled between render and click */ }
          },
        }

        ctx.slots.inject('shell.overlay', () => ctx.slots.register({
          name: 'shell.overlay', id: 'agent-overlay', order: 60,
        }, () => h(Guard, null, h(Launcher, { api, t }))))

        ctx.effect(() => startBridge(api, t), 'agent-overlay: native host bridge')
      },
    }
  },
})
