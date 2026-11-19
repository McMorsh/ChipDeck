/**
 * Loopback bridge between the DSH web page and the native overlay window.
 *
 * The page (a client plugin) pushes its model to `/state` and polls
 * `/commands`; this process is the only writer of the two files the WPF
 * window reads and writes. No dependencies: plain node:http.
 *
 * Security: binds 127.0.0.1 only. Cross-origin responses are limited to
 * localhost pages, so a remote site cannot read the commands or drive the
 * overlay. Commands are executed by the page itself.
 */
'use strict'

const http = require('node:http')
const fs = require('node:fs')
const path = require('node:path')

const PORT = Number(process.env.CHIPDECK_PORT ?? 5199)
const HOST = '127.0.0.1'
const DIR = process.env.CHIPDECK_DIR ?? path.join(process.env.LOCALAPPDATA ?? process.env.TEMP, 'chipdeck')
const STATE = path.join(DIR, 'state.json')
const COMMANDS = path.join(DIR, 'commands.json')
const FOCUS = path.join(DIR, 'focus.flag')
const MAX_BODY = 256 * 1024

fs.mkdirSync(DIR, { recursive: true })

/** Allow only requests coming from a page served by this machine. */
function allowedOrigin(origin) {
  if (origin === undefined || origin === '') return null
  try {
    const { hostname } = new URL(origin)
    return hostname === '127.0.0.1' || hostname === 'localhost' || hostname === '::1' ? origin : null
  } catch {
    return null
  }
}

function send(req, res, code, body) {
  const payload = typeof body === 'string' ? body : JSON.stringify(body)
  const origin = allowedOrigin(req.headers.origin)
  const headers = {
    'content-type': 'application/json; charset=utf-8',
    'content-length': Buffer.byteLength(payload),
    'cache-control': 'no-store',
  }
  if (origin !== null) {
    headers['access-control-allow-origin'] = origin
    headers['access-control-allow-headers'] = 'content-type'
    headers['access-control-allow-methods'] = 'GET, POST, OPTIONS'
    headers['vary'] = 'origin'
  }
  res.writeHead(code, headers)
  res.end(payload)
}

/** Read a request body with a size cap. */
function readBody(req) {
  return new Promise((resolve, reject) => {
    const chunks = []
    let size = 0
    req.on('data', (chunk) => {
      size += chunk.length
      if (size > MAX_BODY) {
        reject(new Error('body too large'))
        req.destroy()
        return
      }
      chunks.push(chunk)
    })
    req.on('end', () => resolve(Buffer.concat(chunks).toString('utf8')))
    req.on('error', reject)
  })
}

/** Replace a file atomically so the window never reads a half-written state. */
function writeAtomic(target, text) {
  const temporary = `${target}.${process.pid}.tmp`
  fs.writeFileSync(temporary, text, 'utf8')
  fs.renameSync(temporary, target)
}

/** Hand out queued overlay commands once. */
function takeCommands() {
  let text
  try { text = fs.readFileSync(COMMANDS, 'utf8') } catch { return [] }
  try { fs.unlinkSync(COMMANDS) } catch { /* the window may rewrite it */ }
  try {
    const parsed = JSON.parse(text)
    return Array.isArray(parsed) ? parsed : []
  } catch {
    return []
  }
}

const server = http.createServer(async (req, res) => {
  const url = new URL(req.url ?? '/', `http://${HOST}:${PORT}`)
  const route = `${req.method ?? 'GET'} ${url.pathname}`

  if (req.method === 'OPTIONS') {
    send(req, res, 204, '')
    return
  }

  try {
    switch (route) {
      case 'GET /health':
        send(req, res, 200, { ok: true, pid: process.pid, dir: DIR })
        return
      case 'POST /state': {
        const body = await readBody(req)
        JSON.parse(body)
        writeAtomic(STATE, body)
        send(req, res, 200, { ok: true })
        return
      }
      case 'GET /commands':
        send(req, res, 200, takeCommands())
        return
      case 'POST /focus':
        writeAtomic(FOCUS, String(Date.now()))
        send(req, res, 200, { ok: true })
        return
      case 'GET /focus':
        send(req, res, 200, { ok: true })
        return
      case 'POST /shutdown':
        send(req, res, 200, { ok: true })
        setTimeout(() => process.exit(0), 120)
        return
      default:
        send(req, res, 404, { ok: false, error: 'not found' })
    }
  } catch (error) {
    send(req, res, 400, { ok: false, error: String(error && error.message ? error.message : error) })
  }
})

server.on('error', (error) => {
  if (error && error.code === 'EADDRINUSE') {
    // Another bridge instance already serves the page; nothing to do.
    process.exit(0)
  }
  process.stderr.write(`dsh-overlay bridge: ${String(error)}\n`)
  process.exit(1)
})

server.listen(PORT, HOST, () => {
  process.stdout.write(`dsh-overlay bridge listening on http://${HOST}:${PORT}\n`)
})

for (const signal of ['SIGINT', 'SIGTERM']) {
  process.on(signal, () => process.exit(0))
}
