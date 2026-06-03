#!/usr/bin/env node
'use strict'

const http = require('http')
const fs   = require('fs')
const path = require('path')

const PORT         = parseInt(process.env.PORT || '3000', 10)
const CONDUCTOR_DIR = process.env.CONDUCTOR_DIR || '.conductor'
const KANBAN_DIR   = path.resolve(CONDUCTOR_DIR, 'kanban')
const COLUMNS      = ['backlog','ready','in-progress','validation','review','merge-pending','merging','done']

// ---------------------------------------------------------------------------
// Frontmatter parser — scalars kept as strings, lists stored as item count
// ---------------------------------------------------------------------------
function parseFrontmatter(content) {
  const m = content.match(/^---\r?\n([\s\S]*?)\r?\n---/)
  if (!m) return {}
  const fm = {}
  let listKey = null
  for (const line of m[1].split('\n')) {
    if (/^  - /.test(line)) {
      if (listKey !== null) fm[listKey] = (fm[listKey] || 0) + 1
    } else {
      listKey = null
      const ci = line.indexOf(': ')
      if (ci !== -1) {
        const key = line.slice(0, ci).trim()
        const val = line.slice(ci + 2).trim()
        if (val === '') { listKey = key; fm[key] = 0 }
        else fm[key] = val
      } else if (line.endsWith(':')) {
        listKey = line.slice(0, -1).trim()
        fm[listKey] = 0
      }
    }
  }
  return fm
}

function readBoard() {
  const board = {}
  for (const col of COLUMNS) {
    board[col] = []
    const dir = path.join(KANBAN_DIR, col)
    if (!fs.existsSync(dir)) continue
    for (const f of fs.readdirSync(dir).sort()) {
      if (!f.endsWith('.md')) continue
      try {
        board[col].push(parseFrontmatter(fs.readFileSync(path.join(dir, f), 'utf8')))
      } catch (_) {}
    }
  }
  return board
}

// ---------------------------------------------------------------------------
// SSE broadcast
// ---------------------------------------------------------------------------
const clients = new Set()

function broadcast() {
  const data = `data: ${JSON.stringify(readBoard())}\n\n`
  for (const res of clients) {
    try { res.write(data) } catch (_) { clients.delete(res) }
  }
}

function watchKanban() {
  fs.watch(KANBAN_DIR, { recursive: true }, broadcast)
  console.log(`Watching ${KANBAN_DIR}`)
}

if (fs.existsSync(KANBAN_DIR)) {
  watchKanban()
} else {
  console.log(`Waiting for ${KANBAN_DIR} ...`)
  const poll = setInterval(() => {
    if (fs.existsSync(KANBAN_DIR)) { clearInterval(poll); watchKanban(); broadcast() }
  }, 1000)
}

// ---------------------------------------------------------------------------
// HTML — single-file board rendered client-side from SSE JSON
// ---------------------------------------------------------------------------
const HTML = /* html */`<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<title>Swarm Kanban</title>
<meta name="viewport" content="width=device-width,initial-scale=1">
<style>
  *, *::before, *::after { box-sizing: border-box; margin: 0; padding: 0 }

  :root {
    --bg:        #f1f5f9;
    --surface:   #ffffff;
    --border:    #e2e8f0;
    --text:      #1e293b;
    --muted:     #64748b;
    --radius:    8px;
    --col-width: 220px;

    --backlog:      #94a3b8;
    --ready:        #38bdf8;
    --in-progress:  #fb923c;
    --review:       #a78bfa;
    --merge-pending:#fbbf24;
    --merging:      #34d399;
    --done:         #4ade80;
  }

  body {
    font-family: system-ui, -apple-system, sans-serif;
    background: var(--bg);
    color: var(--text);
    height: 100vh;
    display: flex;
    flex-direction: column;
    overflow: hidden;
  }

  /* ── Header ── */
  header {
    display: flex;
    align-items: center;
    gap: 12px;
    padding: 12px 20px;
    background: var(--surface);
    border-bottom: 1px solid var(--border);
    flex-shrink: 0;
  }
  header h1 { font-size: 15px; font-weight: 600; letter-spacing: -.3px }
  header .spacer { flex: 1 }
  header .meta { font-size: 12px; color: var(--muted) }

  .status-dot {
    width: 8px; height: 8px; border-radius: 50%;
    background: #94a3b8; flex-shrink: 0;
    transition: background .3s;
  }
  .status-dot.live         { background: #4ade80 }
  .status-dot.reconnecting { background: #fbbf24 }

  /* ── Board ── */
  #board {
    display: flex;
    gap: 12px;
    padding: 16px 20px;
    overflow-x: auto;
    flex: 1;
    align-items: flex-start;
  }

  /* ── Column ── */
  .col {
    flex-shrink: 0;
    width: var(--col-width);
    display: flex;
    flex-direction: column;
    gap: 8px;
  }

  .col-header {
    display: flex;
    align-items: center;
    gap: 6px;
    padding: 0 2px 6px;
    border-bottom: 2px solid var(--accent);
  }
  .col-header .col-name {
    font-size: 11px;
    font-weight: 700;
    text-transform: uppercase;
    letter-spacing: .6px;
    color: var(--text);
  }
  .col-header .count {
    margin-left: auto;
    font-size: 11px;
    font-weight: 600;
    color: var(--muted);
    background: var(--border);
    border-radius: 10px;
    padding: 1px 6px;
  }

  /* ── Card ── */
  .card {
    background: var(--surface);
    border: 1px solid var(--border);
    border-radius: var(--radius);
    padding: 10px;
    display: flex;
    flex-direction: column;
    gap: 7px;
    box-shadow: 0 1px 2px rgba(0,0,0,.04);
    transition: box-shadow .15s;
  }
  .card:hover { box-shadow: 0 3px 8px rgba(0,0,0,.08) }

  .card-badges { display: flex; gap: 4px; flex-wrap: wrap }

  .badge {
    font-size: 10px;
    font-weight: 600;
    padding: 2px 6px;
    border-radius: 4px;
    text-transform: uppercase;
    letter-spacing: .4px;
  }
  .badge.feature      { background: #eff6ff; color: #3b82f6 }
  .badge.test         { background: #f5f3ff; color: #7c3aed }
  .badge.chore        { background: #f1f5f9; color: #64748b }
  .badge.spike        { background: #fff7ed; color: #ea580c }
  .badge.design       { background: #ecfeff; color: #0891b2 }

  .badge.high         { background: #fef2f2; color: #dc2626 }
  .badge.normal       { background: #f8fafc; color: #94a3b8 }
  .badge.low          { background: #f8fafc; color: #cbd5e1 }

  .card-title {
    font-size: 13px;
    font-weight: 500;
    line-height: 1.35;
    color: var(--text);
  }

  .card-footer {
    display: flex;
    align-items: center;
    gap: 6px;
    margin-top: 2px;
  }
  .worker-chip {
    font-size: 10px;
    color: var(--muted);
    background: var(--bg);
    border-radius: 4px;
    padding: 1px 5px;
  }
  .card-footer .spacer { flex: 1 }
  .timestamp {
    font-size: 10px;
    color: #cbd5e1;
  }
  .files-badge {
    font-size: 10px;
    color: var(--muted);
    background: var(--border);
    border-radius: 4px;
    padding: 1px 5px;
  }

  .empty { font-size: 11px; color: #cbd5e1; text-align: center; padding: 12px 0 }
</style>
</head>
<body>

<header>
  <div class="status-dot" id="dot"></div>
  <h1>Swarm Kanban</h1>
  <div class="spacer"></div>
  <span class="meta" id="meta">connecting...</span>
</header>

<div id="board"></div>

<script>
  const COLUMNS = ['backlog','ready','in-progress','validation','review','merge-pending','merging','done']
  const ACCENT  = {
    'backlog':       '#94a3b8',
    'ready':         '#38bdf8',
    'in-progress':   '#fb923c',
    'validation':    '#f472b6',
    'review':        '#a78bfa',
    'merge-pending': '#fbbf24',
    'merging':       '#34d399',
    'done':          '#4ade80',
  }

  const dot   = document.getElementById('dot')
  const meta  = document.getElementById('meta')
  const board = document.getElementById('board')

  function fmt(ts) {
    if (!ts) return ''
    // ts: 20240115-100000 → "Jan 15 10:00"
    const d = ts.replace(/^(\d{4})(\d{2})(\d{2})-(\d{2})(\d{2})(\d{2})$/,
      '$1-$2-$3T$4:$5:$6')
    const dt = new Date(d)
    if (isNaN(dt)) return ts
    return dt.toLocaleDateString(undefined, { month:'short', day:'numeric' })
      + ' ' + dt.toLocaleTimeString(undefined, { hour:'2-digit', minute:'2-digit' })
  }

  function card(fm) {
    const type   = fm.type     || ''
    const pri    = fm.priority || ''
    const worker = fm['worker-type'] || ''
    const files  = fm['files-changed']
    const ts     = fm['last-updated'] || ''

    const badges = [
      type ? \`<span class="badge \${type}">\${type}</span>\` : '',
      (pri && pri !== 'normal') ? \`<span class="badge \${pri}">\${pri}</span>\` : '',
    ].filter(Boolean).join('')

    const footer = [
      worker ? \`<span class="worker-chip">@\${worker}</span>\` : '',
      '<span class="spacer"></span>',
      files   ? \`<span class="files-badge">\${files}f</span>\` : '',
      ts      ? \`<span class="timestamp">\${fmt(ts)}</span>\` : '',
    ].filter(Boolean).join('')

    return \`
      <div class="card">
        \${badges ? \`<div class="card-badges">\${badges}</div>\` : ''}
        <div class="card-title">\${esc(fm.title || fm.id || '—')}</div>
        \${footer ? \`<div class="card-footer">\${footer}</div>\` : ''}
      </div>\`
  }

  function esc(s) {
    return String(s)
      .replace(/&/g,'&amp;').replace(/</g,'&lt;')
      .replace(/>/g,'&gt;').replace(/"/g,'&quot;')
  }

  // Transition states collapsed into in-progress for cleaner display
  const IN_PROGRESS_COLS = new Set(['ready','in-progress','validation','review','merge-pending','merging'])
  const DISPLAY_COLS     = ['backlog', 'in-progress', 'done']

  function normalise(data) {
    const out = { backlog: [], 'in-progress': [], done: [] }
    for (const [col, cards] of Object.entries(data)) {
      if (col === 'backlog')      out['backlog'].push(...cards)
      else if (col === 'done')    out['done'].push(...cards)
      else if (IN_PROGRESS_COLS.has(col)) out['in-progress'].push(...cards)
    }
    return out
  }

  function render(data) {
    const view  = normalise(data)
    let total   = 0
    const active = DISPLAY_COLS.filter(col => view[col].length > 0)
    board.innerHTML = active.map(col => {
      const cards = view[col]
      total += cards.length
      const accent = ACCENT[col] || '#94a3b8'
      return \`
        <div class="col" style="--accent:\${accent}">
          <div class="col-header">
            <span class="col-name">\${col}</span>
            <span class="count">\${cards.length}</span>
          </div>
          \${cards.map(card).join('')}
        </div>\`
    }).join('')
    meta.textContent = \`\${total} task\${total !== 1 ? 's' : ''} · \${new Date().toLocaleTimeString()}\`
  }

  function connect() {
    const es = new EventSource('/events')
    es.onopen    = () => { dot.className = 'status-dot live' }
    es.onerror   = () => { dot.className = 'status-dot reconnecting' }
    es.onmessage = e  => { render(JSON.parse(e.data)) }
  }

  connect()
</script>
</body>
</html>`

// ---------------------------------------------------------------------------
// HTTP server
// ---------------------------------------------------------------------------
const server = http.createServer((req, res) => {
  if (req.url === '/events') {
    res.writeHead(200, {
      'Content-Type':  'text/event-stream',
      'Cache-Control': 'no-cache',
      'Connection':    'keep-alive',
    })
    clients.add(res)
    res.write(`data: ${JSON.stringify(readBoard())}\n\n`)
    req.on('close', () => clients.delete(res))
  } else {
    res.writeHead(200, { 'Content-Type': 'text/html; charset=utf-8' })
    res.end(HTML)
  }
})

server.on('error', (err) => {
  if (err.code === 'EADDRINUSE') {
    console.error(`Port ${PORT} is already in use. Use PORT=<n> to choose another.`)
    process.exit(1)
  }
  throw err
})

server.listen(PORT, () => {
  console.log(`Kanban board → http://localhost:${PORT}`)
})
