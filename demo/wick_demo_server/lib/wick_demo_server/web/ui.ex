defmodule WickDemoServer.Web.Ui do
  @moduledoc """
  The demo UI, as one self-contained HTML page.

  ## Why a single file and no build step

  Leshan's demo server ships a Vue SPA, which means its build needs Node and npm alongside
  Maven. That is a real cost for something whose job is to demonstrate a protocol library, and
  it is a cost this demo declines: `iex -S mix` is the whole toolchain. Everything — markup,
  styles, and the ~400 lines of vanilla JS that drive it — is inlined here and served by
  `WickDemoServer.Web.Router`.

  The trade is honest: no components, no reactive framework, and the JS is imperative
  DOM-building. At this size that is simpler to read than the equivalent framework setup, and
  the page has exactly one job.

  ## Design

  Monochrome light/dark via `prefers-color-scheme`, Inter for text, JetBrains Mono for anything
  that is really data (paths, codes, payloads), 16/24px radii, hairline borders rather than
  shadows. No CSS framework — the whole system is a dozen custom properties.

  Two accents carry meaning rather than decoration, which is why there are only two:

  * **Teal** — live protocol activity. An active Observe relation, an arriving Notification.
  * **Purple** — server-initiated operations, so an outbound Read reads differently from an
    inbound Notify in the event log.

  Success and failure keep their own green/red, because a `4.04` must not be mistakable for a
  `2.05` on a glance.
  """

  @page ~S"""
  <!doctype html>
  <html lang="en">
  <head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>Wick — LwM2M Demo Server</title>
  <link rel="icon" href="data:image/svg+xml,<svg xmlns='http://www.w3.org/2000/svg' viewBox='0 0 100 100'><rect width='100' height='100' rx='22' fill='%230a0a0b'/><path d='M22 34h11l6 24 7-24h8l7 24 6-24h11L67 70h-9l-8-24-8 24h-9z' fill='%23fff'/></svg>">
  <style>
  @import url('https://fonts.googleapis.com/css2?family=Inter:wght@300;400;500;600;700;800;900&family=JetBrains+Mono:wght@400;500;600&display=swap');

  /* ── Tokens: a monochrome scale, plus exactly two accents ── */
  :root {
    --ink:#0a0a0b; --ink-2:#2b2b2e; --muted:#6b6b70; --faint:#97979c;
    --line:#e2e2e4; --line-2:#d0d0d3;
    --surface:#ffffff; --surface-2:#f6f6f7; --bg:#fbfbfc; --bg-2:#f2f2f3;
    --hero-bg:#0a0a0b; --hero-fg:#f7f7f8; --hero-line:rgba(255,255,255,.14);
    --teal:#0d9488; --teal-bg:rgba(13,148,136,.10); --teal-line:rgba(13,148,136,.28);
    --purple:#7c3aed; --purple-bg:rgba(124,58,237,.10); --purple-line:rgba(124,58,237,.26);
    --green:#047857; --green-bg:rgba(4,120,87,.10);
    --red:#b91c1c;   --red-bg:rgba(185,28,28,.09);
    --amber:#a16207; --amber-bg:rgba(161,98,7,.10);
    --radius:16px; --radius-lg:24px; --maxw:1320px;
  }
  @media (prefers-color-scheme: dark) {
    :root {
      --ink:#f4f4f5; --ink-2:#d4d4d8; --muted:#9a9aa1; --faint:#6c6c73;
      --line:rgba(255,255,255,.10); --line-2:rgba(255,255,255,.17);
      --surface:#101012; --surface-2:#16161a; --bg:#08080a; --bg-2:#0d0d0f;
      --hero-bg:#050506; --hero-line:rgba(255,255,255,.12);
      --teal:#2dd4bf; --teal-bg:rgba(45,212,191,.12); --teal-line:rgba(45,212,191,.30);
      --purple:#a78bfa; --purple-bg:rgba(167,139,250,.13); --purple-line:rgba(167,139,250,.30);
      --green:#34d399; --green-bg:rgba(52,211,153,.12);
      --red:#f87171;   --red-bg:rgba(248,113,113,.12);
      --amber:#fbbf24; --amber-bg:rgba(251,191,36,.12);
    }
  }

  *{box-sizing:border-box}
  html{-webkit-text-size-adjust:100%}
  body{
    margin:0; background:var(--bg); color:var(--ink);
    font-family:'Inter',system-ui,-apple-system,sans-serif; line-height:1.6;
    font-feature-settings:'cv05','ss01'; -webkit-font-smoothing:antialiased;
  }
  .mono{font-family:'JetBrains Mono',ui-monospace,monospace}
  h1,h2,h3{margin:0; font-weight:800; letter-spacing:-.025em; line-height:1.1}
  a{color:inherit;text-decoration:none}
  button{font-family:inherit}

  /* ── Header ── */
  header{
    position:sticky; top:0; z-index:60; background:var(--hero-bg); color:var(--hero-fg);
    border-bottom:1px solid var(--hero-line);
  }
  .hwrap{max-width:var(--maxw); margin:0 auto; padding:0 22px;
    height:60px; display:flex; align-items:center; gap:18px}
  .brand{display:flex; align-items:center; gap:11px; font-weight:800;
    letter-spacing:-.02em; font-size:17px; flex:none}
  .brand svg{width:24px;height:24px;display:block}
  .brand .tag{
    font-family:'JetBrains Mono',monospace; font-size:10px; letter-spacing:.16em;
    text-transform:uppercase; color:rgba(255,255,255,.5);
    border-left:1px solid var(--hero-line); padding-left:11px; margin-left:2px; font-weight:500;
  }
  .stats{margin-left:auto; display:flex; gap:6px; align-items:center; flex-wrap:wrap}
  .stat{
    font-family:'JetBrains Mono',monospace; font-size:11px; letter-spacing:.04em;
    color:rgba(255,255,255,.62); background:rgba(255,255,255,.06);
    border:1px solid var(--hero-line); border-radius:999px; padding:4px 11px; white-space:nowrap;
  }
  .stat b{color:#fff; font-weight:600}
  .live{display:inline-flex;align-items:center;gap:7px}
  .dot{width:6px;height:6px;border-radius:50%;background:var(--teal);flex:none}
  .dot.on{animation:pulse 2s ease-in-out infinite}
  .dot.off{background:var(--red);animation:none}
  @keyframes pulse{0%,100%{opacity:1}50%{opacity:.25}}

  /* ── Layout ── */
  main{max-width:var(--maxw); margin:0 auto; padding:22px}
  .cols{display:grid; grid-template-columns:300px minmax(0,1fr) 360px; gap:18px; align-items:start}
  @media (max-width:1240px){ .cols{grid-template-columns:280px minmax(0,1fr)} .col-events{grid-column:1/-1} }
  @media (max-width:880px){ .cols{grid-template-columns:1fr} }
  .stack{display:flex;flex-direction:column;gap:18px}

  /* ── Cards ── */
  .card{background:var(--surface); border:1px solid var(--line); border-radius:var(--radius); overflow:hidden}
  .card-h{
    display:flex; align-items:center; gap:10px; padding:13px 16px;
    border-bottom:1px solid var(--line); background:var(--surface-2);
  }
  .card-h h2{font-size:12px; font-weight:700; letter-spacing:.13em; text-transform:uppercase;
    color:var(--muted); font-family:'JetBrains Mono',monospace}
  .card-h .right{margin-left:auto; display:flex; gap:6px; align-items:center}
  .card-b{padding:16px}
  .card-b.flush{padding:0}
  .empty{padding:30px 20px; text-align:center; color:var(--faint); font-size:13px}
  .empty code{font-size:12px}

  /* ── Client list ── */
  .client{
    display:block; width:100%; text-align:left; padding:13px 16px; border:0;
    border-bottom:1px solid var(--line); background:transparent; cursor:pointer;
    color:inherit; transition:background .12s;
  }
  .client:last-child{border-bottom:0}
  .client:hover{background:var(--surface-2)}
  .client.sel{background:var(--teal-bg); box-shadow:inset 2px 0 0 var(--teal)}
  .client .ep{font-weight:650; font-size:14px; letter-spacing:-.01em; word-break:break-all}
  .client .sub{
    font-family:'JetBrains Mono',monospace; font-size:11px; color:var(--muted);
    margin-top:3px; display:flex; gap:9px; flex-wrap:wrap;
  }

  /* ── Badges ── */
  .badge{
    display:inline-flex; align-items:center; gap:5px; font-family:'JetBrains Mono',monospace;
    font-size:10.5px; font-weight:500; letter-spacing:.06em; text-transform:uppercase;
    padding:2.5px 8px; border-radius:999px; border:1px solid var(--line-2); color:var(--muted);
    white-space:nowrap;
  }
  .badge.ok{color:var(--green); background:var(--green-bg); border-color:transparent}
  .badge.err{color:var(--red); background:var(--red-bg); border-color:transparent}
  .badge.teal{color:var(--teal); background:var(--teal-bg); border-color:var(--teal-line)}
  .badge.purple{color:var(--purple); background:var(--purple-bg); border-color:var(--purple-line)}
  .badge.amber{color:var(--amber); background:var(--amber-bg); border-color:transparent}

  /* ── Object tree ── */
  .obj{border-bottom:1px solid var(--line)}
  .obj:last-child{border-bottom:0}
  .obj-h{
    display:flex; align-items:center; gap:10px; padding:11px 16px; cursor:pointer;
    background:transparent; border:0; width:100%; text-align:left; color:inherit;
  }
  .obj-h:hover{background:var(--surface-2)}
  .obj-h .oid{font-family:'JetBrains Mono',monospace; font-size:12px; color:var(--muted);
    min-width:44px; font-weight:500}
  .obj-h .oname{font-weight:600; font-size:13.5px; letter-spacing:-.01em}
  .obj-h .chev{margin-left:auto; color:var(--faint); transition:transform .15s; flex:none}
  .obj-h[aria-expanded="true"] .chev{transform:rotate(90deg)}
  .inst{padding:0 16px 14px 16px; display:flex; flex-direction:column; gap:10px}
  .inst-row{
    border:1px solid var(--line); border-radius:12px; background:var(--bg);
    padding:11px 12px; display:flex; flex-direction:column; gap:9px;
  }
  .inst-top{display:flex; align-items:center; gap:9px; flex-wrap:wrap}
  .inst-top .p{font-family:'JetBrains Mono',monospace; font-size:12.5px; font-weight:500}
  .ops{display:flex; gap:5px; flex-wrap:wrap; margin-left:auto}

  /* ── Buttons ── */
  .btn{
    font-size:11.5px; font-weight:600; letter-spacing:.02em; padding:5px 10px;
    border-radius:8px; border:1px solid var(--line-2); background:var(--surface);
    color:var(--ink-2); cursor:pointer; transition:all .12s; white-space:nowrap;
  }
  .btn:hover{border-color:var(--ink); color:var(--ink)}
  .btn:active{transform:translateY(.5px)}
  .btn:disabled{opacity:.45; cursor:not-allowed}
  .btn.p{background:var(--purple-bg); border-color:var(--purple-line); color:var(--purple)}
  .btn.p:hover{border-color:var(--purple)}
  .btn.t{background:var(--teal-bg); border-color:var(--teal-line); color:var(--teal)}
  .btn.t:hover{border-color:var(--teal)}
  .btn.on{background:var(--teal); border-color:var(--teal); color:#fff}
  .btn.on:hover{filter:brightness(1.08)}
  .btn.d{color:var(--red); border-color:var(--line-2)}
  .btn.d:hover{border-color:var(--red)}
  .btn.sm{font-size:11px; padding:4px 9px}

  /* ── Result panel ── */
  .res{border-top:1px dashed var(--line-2); padding-top:9px; display:flex;
    flex-direction:column; gap:7px}
  .res-h{display:flex; align-items:center; gap:8px; flex-wrap:wrap}
  .res-h .op{font-family:'JetBrains Mono',monospace; font-size:11px; color:var(--muted);
    letter-spacing:.06em; text-transform:uppercase}
  table.kv{width:100%; border-collapse:collapse; font-size:12.5px}
  table.kv td{padding:4px 0; vertical-align:top; border-bottom:1px solid var(--line)}
  table.kv tr:last-child td{border-bottom:0}
  table.kv td.k{font-family:'JetBrains Mono',monospace; color:var(--muted); font-size:11.5px;
    white-space:nowrap; padding-right:14px; width:1%}
  table.kv td.v{font-family:'JetBrains Mono',monospace; word-break:break-word; color:var(--ink)}
  table.kv td.v .ty{color:var(--faint); font-size:10.5px; margin-left:6px}
  pre.out{
    margin:0; padding:10px 11px; background:var(--surface-2); border:1px solid var(--line);
    border-radius:10px; font-family:'JetBrains Mono',monospace; font-size:11.5px;
    overflow-x:auto; color:var(--ink-2); line-height:1.55;
  }

  /* ── Forms ── */
  .form{display:flex; flex-direction:column; gap:9px; border-top:1px dashed var(--line-2);
    padding-top:10px}
  .row{display:flex; gap:7px; align-items:center; flex-wrap:wrap}
  .row > label{font-family:'JetBrains Mono',monospace; font-size:10.5px; color:var(--muted);
    letter-spacing:.08em; text-transform:uppercase; min-width:74px}
  input[type=text],input[type=number],select{
    font-family:'JetBrains Mono',monospace; font-size:12px; padding:5px 9px;
    border:1px solid var(--line-2); border-radius:8px; background:var(--bg);
    color:var(--ink); min-width:0; flex:1;
  }
  input:focus,select:focus{outline:2px solid var(--teal); outline-offset:-1px;
    border-color:transparent}
  .hint{font-size:11px; color:var(--faint); line-height:1.5}

  /* ── Event log ── */
  .log{max-height:calc(100vh - 190px); overflow-y:auto; overflow-x:hidden}
  .ev{
    display:flex; gap:9px; padding:9px 14px; border-bottom:1px solid var(--line);
    font-size:12px; align-items:baseline;
  }
  .ev:last-child{border-bottom:0}
  .ev .t{font-family:'JetBrains Mono',monospace; font-size:10.5px; color:var(--faint);
    flex:none; padding-top:2px}
  .ev .body{min-width:0; flex:1}
  .ev .ttl{font-weight:600; font-size:12px; letter-spacing:-.005em}
  .ev .det{font-family:'JetBrains Mono',monospace; font-size:11px; color:var(--muted);
    word-break:break-word; margin-top:1px}
  .ev.new{animation:flash 1.1s ease-out}
  @keyframes flash{from{background:var(--teal-bg)}to{background:transparent}}

  /* ── Misc ── */
  .toast{
    position:fixed; bottom:18px; left:50%; transform:translateX(-50%);
    background:var(--hero-bg); color:var(--hero-fg); padding:10px 18px;
    border-radius:999px; font-size:12.5px; z-index:100; border:1px solid var(--hero-line);
    box-shadow:0 8px 30px rgba(0,0,0,.28); opacity:0; transition:opacity .2s; pointer-events:none;
  }
  .toast.show{opacity:1}
  .toast.bad{background:var(--red); border-color:transparent}
  .spin{display:inline-block;width:9px;height:9px;border:1.5px solid currentColor;
    border-right-color:transparent;border-radius:50%;animation:sp .6s linear infinite}
  @keyframes sp{to{transform:rotate(360deg)}}
  .sr{position:absolute;width:1px;height:1px;overflow:hidden;clip:rect(0 0 0 0)}
  </style>
  </head>
  <body>

  <header>
    <div class="hwrap">
      <div class="brand">
        <svg viewBox="0 0 100 100" aria-hidden="true">
          <rect width="100" height="100" rx="22" fill="currentColor" opacity=".12"/>
          <path d="M22 34h11l6 24 7-24h8l7 24 6-24h11L67 70h-9l-8-24-8 24h-9z" fill="currentColor"/>
        </svg>
        Wick<span class="tag">LwM2M Demo Server</span>
      </div>
      <div class="stats" id="stats"></div>
    </div>
  </header>

  <main>
    <div class="cols">
      <!-- Clients -->
      <div class="stack">
        <div class="card">
          <div class="card-h">
            <h2>Clients</h2>
            <div class="right"><span class="badge" id="client-count">0</span></div>
          </div>
          <div class="card-b flush" id="clients">
            <div class="empty">
              No registered clients.<br>
              Start one with <code>cd apps/wick_demo_client &amp;&amp; iex -S mix</code>
            </div>
          </div>
        </div>

        <div class="card">
          <div class="card-h"><h2>Observations</h2>
            <div class="right"><span class="badge teal" id="obs-count">0</span></div></div>
          <div class="card-b flush" id="observations">
            <div class="empty">No active Observe relations.</div>
          </div>
        </div>
      </div>

      <!-- Object tree -->
      <div class="stack">
        <div class="card">
          <div class="card-h">
            <h2 id="tree-title">Object Tree</h2>
            <div class="right" id="tree-actions"></div>
          </div>
          <div class="card-b flush" id="tree">
            <div class="empty">Select a client to browse its Objects.</div>
          </div>
        </div>
      </div>

      <!-- Events -->
      <div class="stack col-events">
        <div class="card">
          <div class="card-h">
            <h2>Event Log</h2>
            <div class="right">
              <button class="btn sm" id="clear-log">Clear</button>
            </div>
          </div>
          <div class="card-b flush log" id="log">
            <div class="empty">Waiting for protocol activity…</div>
          </div>
        </div>
      </div>
    </div>
  </main>

  <div class="toast" id="toast" role="status" aria-live="polite"></div>

  <script>
  "use strict";

  // ── State ────────────────────────────────────────────────────────────────────
  const S = {
    clients: [],        // registrations from /api/registrations
    selected: null,     // registration_id
    tree: [],           // advertised Object tree for the selected client
    observations: [],   // all live relations
    open: new Set(),    // expanded object ids, so a refresh doesn't collapse the tree
    results: new Map(), // path -> last operation result, keyed so each row keeps its own
    forms: new Map(),   // path -> "w" | "x" | "a": which form is open on that row
    drafts: new Map(),  // path -> whatever has been typed into that row's form
    events: [],         // event log, newest first
    connected: false,
  };
  const MAX_EVENTS = 300;

  // ── Tiny DOM helpers ─────────────────────────────────────────────────────────
  const el = (tag, attrs = {}, ...kids) => {
    const n = document.createElement(tag);

    // Tolerate `el("tr", el("td"), …)` — an easy slip, and one that fails silently otherwise:
    // Object.entries on a DOM node yields nothing, so the element would be dropped rather than
    // appended. Treat a Node or string in the attrs position as the first child instead.
    if (attrs instanceof Node || typeof attrs === "string") {
      kids.unshift(attrs);
      attrs = {};
    }

    for (const [k, v] of Object.entries(attrs)) {
      if (v === null || v === undefined || v === false) continue;
      if (k === "class") n.className = v;
      else if (k === "text") n.textContent = v;
      else if (k.startsWith("on")) n.addEventListener(k.slice(2), v);
      else n.setAttribute(k, v);
    }
    for (const kid of kids.flat()) {
      if (kid === null || kid === undefined || kid === false) continue;
      n.appendChild(typeof kid === "string" ? document.createTextNode(kid) : kid);
    }
    return n;
  };
  const $ = (id) => document.getElementById(id);
  const clear = (node) => { while (node.firstChild) node.removeChild(node.firstChild); };

  let toastTimer;
  function toast(msg, bad = false) {
    const t = $("toast");
    t.textContent = msg;
    t.className = "toast show" + (bad ? " bad" : "");
    clearTimeout(toastTimer);
    toastTimer = setTimeout(() => { t.className = "toast"; }, bad ? 4200 : 2400);
  }

  // ── API ──────────────────────────────────────────────────────────────────────
  async function api(path, body) {
    const res = await fetch(path, body === undefined ? {} : {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify(body),
    });
    const data = await res.json().catch(() => ({}));
    if (!res.ok) throw new Error(data.error || `HTTP ${res.status}`);
    return data;
  }

  // ── Rendering: clients ───────────────────────────────────────────────────────
  function renderClients() {
    const host = $("clients");
    clear(host);
    $("client-count").textContent = S.clients.length;

    if (!S.clients.length) {
      S.selected = null;
      host.appendChild(el("div", { class: "empty" },
        el("div", { text: "No registered clients." }),
        el("div", { style: "margin-top:6px" },
          "Start one with ", el("code", { class: "mono", text: "iex -S mix" }))));
      renderTree();
      return;
    }

    for (const c of S.clients) {
      const sel = c.registration_id === S.selected;
      host.appendChild(el("button", {
        class: "client" + (sel ? " sel" : ""),
        onclick: () => select(c.registration_id),
        "aria-pressed": sel ? "true" : "false",
      },
        el("div", { class: "ep", text: c.endpoint_name }),
        el("div", { class: "sub" },
          el("span", { text: c.registration_id }),
          el("span", { text: `${c.lifetime}s` }),
          el("span", { text: c.peer || "—" })),
        el("div", { class: "sub", style: "margin-top:6px" },
          el("span", { class: "badge" + (c.expires_in < 10 ? " amber" : ""),
                       text: c.expires_in >= 0 ? `renews in ${c.expires_in}s` : "overdue" }))));
    }
  }

  // ── Rendering: observations ──────────────────────────────────────────────────
  function renderObservations() {
    const host = $("observations");
    clear(host);
    $("obs-count").textContent = S.observations.length;

    if (!S.observations.length) {
      host.appendChild(el("div", { class: "empty", text: "No active Observe relations." }));
      return;
    }

    for (const o of S.observations) {
      const client = S.clients.find((c) => c.registration_id === o.registration_id);
      host.appendChild(el("div", { class: "client", style: "cursor:default" },
        el("div", { class: "inst-top" },
          el("span", { class: "mono", style: "font-size:12.5px;font-weight:500",
                       text: o.paths.join(", ") }),
          el("div", { class: "ops" },
            el("button", {
              class: "btn sm d",
              onclick: () => cancelObserve(o),
            }, "Cancel"))),
        el("div", { class: "sub" },
          el("span", { text: client ? client.endpoint_name : o.registration_id }),
          o.composite ? el("span", { class: "badge purple", text: "composite" }) : null,
          o.last_seq !== null ? el("span", { text: `seq ${o.last_seq}` }) : null,
          // Only shown for a single-Resource relation. An Instance-level Notify carries several
          // values, and there is no one of them that is "the" value — the event log has them all.
          o.last_value !== null && o.last_value !== undefined
            ? el("span", { text: `= ${o.last_value}` }) : null)));
    }
  }

  // ── Rendering: object tree ───────────────────────────────────────────────────

  // Which form is open and what has been typed into it are held in `S.forms` / `S.drafts`
  // rather than only in the DOM, so a rebuild re-creates them exactly. That matters because the
  // page redraws on a 5s poll and on protocol events: without this, a half-filled Write form
  // would disappear under you mid-type.
  //
  // On top of that, `renderTreeIfIdle` skips the rebuild entirely when nothing it depends on has
  // changed — which is the common case on a poll tick, and avoids both flicker and losing the
  // text cursor.
  let treeSig = null;

  function treeSignature() {
    return JSON.stringify([
      S.selected,
      S.tree,
      [...S.open].sort(),
      [...S.forms],
      [...S.results].map(([path, r]) => [path, r.op, r.pending || false, r.error || null,
        r.response ? r.response.status : null]),
      S.observations.filter((o) => o.registration_id === S.selected).map((o) => o.paths),
    ]);
  }

  function renderTreeIfIdle() {
    const sig = treeSignature();
    if (sig === treeSig) return;
    renderTree();
  }

  function renderTree() {
    treeSig = treeSignature();
    const host = $("tree");
    const actions = $("tree-actions");
    clear(host); clear(actions);

    const client = S.clients.find((c) => c.registration_id === S.selected);
    $("tree-title").textContent = client ? client.endpoint_name : "Object Tree";

    if (!client) {
      host.appendChild(el("div", { class: "empty", text: "Select a client to browse its Objects." }));
      return;
    }

    actions.appendChild(el("span", { class: "badge", text: client.registration_id }));
    actions.appendChild(el("button", { class: "btn sm", onclick: () => refresh() }, "Refresh"));

    if (!S.tree.length) {
      host.appendChild(el("div", { class: "empty",
        text: "This client advertised no Object Instances." }));
      return;
    }

    for (const obj of S.tree) {
      const open = S.open.has(obj.object_id);
      const head = el("button", {
        class: "obj-h", "aria-expanded": open ? "true" : "false",
        onclick: () => { open ? S.open.delete(obj.object_id) : S.open.add(obj.object_id); renderTree(); },
      },
        el("span", { class: "oid", text: `/${obj.object_id}` }),
        el("span", { class: "oname", text: obj.name || `Object ${obj.object_id}` }),
        el("span", { class: "badge", text: `${obj.instances.length} inst` }),
        el("span", { class: "chev", text: "›" }));

      const wrap = el("div", { class: "obj" }, head);
      if (open) {
        const list = el("div", { class: "inst" });
        for (const inst of obj.instances) list.appendChild(instanceRow(obj, inst));
        wrap.appendChild(list);
      }
      host.appendChild(wrap);
    }
  }

  function instanceRow(obj, inst) {
    const path = inst.path;
    const row = el("div", { class: "inst-row" });

    row.appendChild(el("div", { class: "inst-top" },
      el("span", { class: "p", text: path }),
      el("div", { class: "ops" },
        opBtn("Read", "p", () => run(path, "read", { path })),
        opBtn("Discover", "p", () => run(path, "discover", { path })),
        observeBtn(path),
        opBtn("Delete", "d", () => {
          if (confirmed(`Delete ${path} on the device?`)) run(path, "delete", { path });
        }))));

    // Per-path forms, collapsed behind a toggle so the tree stays scannable.
    const openForm = S.forms.get(path);
    row.appendChild(el("div", { class: "row" },
      formBtn(path, "w", "Write…", openForm),
      formBtn(path, "x", "Execute…", openForm),
      formBtn(path, "a", "Attributes…", openForm)));

    if (openForm === "w") row.appendChild(writeForm(path));
    else if (openForm === "x") row.appendChild(executeForm(path));
    else if (openForm === "a") row.appendChild(attributesForm(path));

    const res = S.results.get(path);
    if (res) row.appendChild(resultPanel(path, res));
    return row;
  }

  const opBtn = (label, kind, onclick) =>
    el("button", { class: "btn" + (kind ? " " + kind : ""), onclick }, label);

  // Only one form open per row: two stacked forms in a tree row is unreadable.
  function formBtn(path, kind, label, openForm) {
    const active = openForm === kind;
    return el("button", {
      class: "btn" + (active ? " t" : ""),
      onclick: () => {
        active ? S.forms.delete(path) : S.forms.set(path, kind);
        renderTree();
      },
    }, label);
  }

  // Drafts are keyed by path so each row keeps its own, and are read back on every render.
  const draft = (path) => S.drafts.get(path) || {};

  function setDraft(path, patch) {
    S.drafts.set(path, { ...draft(path), ...patch });
  }

  // `oninput` rather than `onchange`: a rebuild can happen at any moment, and onchange would
  // not have fired yet for a field still being typed into.
  function bindDraft(node, path, key) {
    node.addEventListener("input", () => setDraft(path, { [key]: node.value }));
    return node;
  }

  function observeBtn(path) {
    const active = S.observations.find(
      (o) => o.registration_id === S.selected && o.paths.length === 1 && o.paths[0] === path);

    return el("button", {
      class: "btn " + (active ? "on" : "t"),
      onclick: () => active ? cancelObserve(active) : observe(path),
    }, active ? "Observing" : "Observe");
  }

  const VALUE_TYPES =
    ["float", "integer", "string", "boolean", "unsigned_integer", "time", "opaque", "objlnk"];

  function writeForm(path) {
    const d = draft(path);

    const type = el("select", { class: "mono" },
      ...VALUE_TYPES.map((t) =>
        el("option", { value: t, text: t, selected: (d.type || "float") === t })));
    const value = el("input", { type: "text", placeholder: "value", value: d.value || "" });
    const mode = el("select", { class: "mono" },
      el("option", { value: "replace", text: "replace (PUT)",
        selected: (d.mode || "replace") === "replace" }),
      el("option", { value: "partial_update", text: "partial (POST)",
        selected: d.mode === "partial_update" }));

    bindDraft(type, path, "type");
    bindDraft(value, path, "value");
    bindDraft(mode, path, "mode");

    const submit = () => run(path, "write", {
      path, mode: mode.value, value: { type: type.value, value: value.value },
    });
    value.addEventListener("keydown", (e) => { if (e.key === "Enter") submit(); });

    return el("div", { class: "form" },
      el("div", { class: "row" }, el("label", { text: "Write" }), type, value),
      el("div", { class: "row" }, el("label", { text: "Mode" }), mode,
        el("button", { class: "btn p", onclick: submit }, "Send")),
      el("div", { class: "hint",
        text: "Replace targets a Resource; partial-update merges into an Object Instance." }));
  }

  function executeForm(path) {
    const d = draft(path);
    const args = el("input", {
      type: "text", placeholder: "arguments (optional), e.g. 1='now'", value: d.args || "",
    });
    bindDraft(args, path, "args");

    const submit = () => run(path, "execute", { path, arguments: args.value || null });
    args.addEventListener("keydown", (e) => { if (e.key === "Enter") submit(); });

    return el("div", { class: "form" },
      el("div", { class: "row" }, el("label", { text: "Execute" }), args,
        el("button", { class: "btn p", onclick: submit }, "Send")),
      el("div", { class: "hint",
        text: "Arguments travel as a text/plain body (§6.4.8.1), and only an Executable Resource accepts them." }));
  }

  const ATTR_FIELDS = ["pmin", "pmax", "gt", "lt", "st"];

  function attributesForm(path) {
    const d = draft(path);
    const inputs = {};

    const rows = ATTR_FIELDS.map((f) => {
      inputs[f] = bindDraft(
        el("input", { type: "text", placeholder: "—", style: "max-width:88px",
                      value: d[f] || "" }), path, f);
      return el("div", { class: "row", style: "flex:1;min-width:118px" },
        el("label", { style: "min-width:34px", text: f }), inputs[f]);
    });

    const submit = () => {
      const attrs = {};
      for (const f of ATTR_FIELDS) {
        const raw = inputs[f].value.trim();
        // Empty means "leave alone"; the word "clear" means remove it on the device. That
        // three-way distinction is exactly what Wick.Attributes' :clear form exists for, and
        // collapsing it would make it impossible to unset an attribute.
        if (raw === "") continue;
        attrs[f] = raw.toLowerCase() === "clear" ? null : raw;
      }
      if (!Object.keys(attrs).length) return toast("Nothing to write", true);
      run(path, "attributes", { path, attributes: attrs });
    };

    return el("div", { class: "form" },
      el("div", { class: "row" }, ...rows),
      el("div", { class: "row" },
        el("button", { class: "btn p", onclick: submit }, "Write attributes"),
        el("span", { class: "hint",
          text: "pmin/pmax seconds; gt/lt/st numeric. Type “clear” to remove one." })));
  }

  // ── Rendering: operation result ──────────────────────────────────────────────
  function resultPanel(path, res) {
    const panel = el("div", { class: "res" });

    if (res.pending) {
      panel.appendChild(el("div", { class: "res-h" },
        el("span", { class: "spin" }),
        el("span", { class: "op", text: res.op })));
      return panel;
    }

    if (res.error) {
      panel.appendChild(el("div", { class: "res-h" },
        el("span", { class: "op", text: res.op }),
        el("span", { class: "badge err", text: "failed" })));
      panel.appendChild(el("pre", { class: "out", text: res.error }));
      return panel;
    }

    const r = res.response;
    panel.appendChild(el("div", { class: "res-h" },
      el("span", { class: "op", text: res.op }),
      el("span", { class: "badge " + (r.success ? "ok" : "err"),
                   text: `${r.coap_code} ${r.status}` }),
      r.location_path ? el("span", { class: "badge purple", text: r.location_path }) : null,
      r.content_format !== null && r.content_format !== undefined
        ? el("span", { class: "badge", text: `ct ${r.content_format}` }) : null));

    if (r.readings && r.readings.length) {
      const t = el("table", { class: "kv" });
      for (const rd of r.readings) {
        t.appendChild(el("tr", {},
          el("td", { class: "k", text: rd.path }),
          el("td", { class: "v" },
            el("span", { text: renderValue(rd.value) }),
            el("span", { class: "ty", text: rd.value ? rd.value.type : "" }))));
      }
      panel.appendChild(t);
    } else if (r.links && r.links.length) {
      const t = el("table", { class: "kv" });
      for (const l of r.links) {
        const params = Object.entries(l.params || {})
          .map(([k, v]) => (v === "" ? k : `${k}=${v}`)).join(" ");
        t.appendChild(el("tr", {},
          el("td", { class: "k", text: l.target }),
          el("td", { class: "v", text: params || "—" })));
      }
      panel.appendChild(t);
    } else if (r.text) {
      panel.appendChild(el("pre", { class: "out", text: r.text }));
    } else if (r.error) {
      panel.appendChild(el("pre", { class: "out", text: r.error }));
    }

    return panel;
  }

  function renderValue(v) {
    if (!v) return "—";
    if (v.value === null || v.value === undefined) return "—";
    if (v.type === "opaque") return `${v.value} (base64)`;
    return String(v.value);
  }

  // ── Operations ───────────────────────────────────────────────────────────────
  async function run(path, op, body) {
    if (!S.selected) return;
    S.results.set(path, { op, pending: true });
    renderTree();

    try {
      const data = await api(`/api/registrations/${S.selected}/${op}`, body);
      S.results.set(path, { op, response: data.response });
      if (data.response && !data.response.success) {
        toast(`${op}: ${data.response.coap_code} ${data.response.status}`, true);
      }
    } catch (e) {
      S.results.set(path, { op, error: e.message });
      toast(`${op} failed: ${e.message}`, true);
    }
    renderTree();
  }

  async function observe(path) {
    try {
      const data = await api(`/api/registrations/${S.selected}/observe`, { path });
      if (data.response && !data.response.success) {
        toast(`Observe refused: ${data.response.coap_code}`, true);
      } else {
        toast(`Observing ${path}`);
      }
      S.observations = await loadObservations();
      renderObservations(); renderTree();
    } catch (e) {
      toast(`Observe failed: ${e.message}`, true);
    }
  }

  async function cancelObserve(o) {
    try {
      await api(`/api/registrations/${o.registration_id}/cancel`,
                { path: o.paths[0], handle: o.handle });
      toast(`Stopped observing ${o.paths[0]}`);
      S.observations = await loadObservations();
      renderObservations(); renderTree();
    } catch (e) {
      toast(`Cancel failed: ${e.message}`, true);
    }
  }

  function confirmed(message) { return window.confirm(message); }

  // ── Loading ──────────────────────────────────────────────────────────────────
  async function loadObservations() {
    const data = await api("/api/observations");
    return data.observations;
  }

  async function select(id) {
    S.selected = id;
    S.results.clear();
    renderClients();
    try {
      const data = await api(`/api/registrations/${id}`);
      S.tree = data.tree;
      // Expand a lone Object automatically — clicking through one collapsed row to reach the
      // only thing there is is pure friction.
      if (S.tree.length === 1) S.open.add(S.tree[0].object_id);
      renderTree();
    } catch (e) {
      toast(e.message, true);
    }
  }

  async function refresh() {
    try {
      const [regs, obs] = await Promise.all([api("/api/registrations"), loadObservations()]);
      S.clients = regs.registrations;
      S.observations = obs;

      // Keep the selection if it survived; otherwise fall back to the first client so the
      // tree pane is never pointlessly empty.
      if (S.selected && !S.clients.some((c) => c.registration_id === S.selected)) {
        S.selected = null; S.tree = [];
      }
      if (!S.selected && S.clients.length) {
        renderClients(); renderObservations();
        return select(S.clients[0].registration_id);
      }
      renderClients(); renderObservations(); renderTreeIfIdle();
    } catch (e) {
      toast(e.message, true);
    }
  }

  async function refreshStats() {
    try {
      const s = await api("/api/summary");
      const host = $("stats");
      clear(host);
      host.appendChild(el("span", { class: "stat live" },
        el("span", { class: "dot " + (S.connected ? "on" : "off") }),
        S.connected ? "live" : "reconnecting"));
      host.appendChild(el("span", { class: "stat" }, "coap ", el("b", { text: `:${s.port}` })));
      host.appendChild(el("span", { class: "stat" }, "clients ",
        el("b", { text: String(s.registrations) })));
      host.appendChild(el("span", { class: "stat" }, "observing ",
        el("b", { text: String(s.observations) })));
      host.appendChild(el("span", { class: "stat" }, "readings ",
        el("b", { text: String(s.readings) })));
    } catch (_e) { /* the stats bar is cosmetic; a blip is not worth a toast */ }
  }

  // ── Event log ────────────────────────────────────────────────────────────────
  const EVENT_STYLE = {
    register:   { title: "REGISTER",    badge: "ok" },
    update:     { title: "UPDATE",      badge: "" },
    deregister: { title: "DEREGISTER",  badge: "" },
    expire:     { title: "EXPIRED",     badge: "amber" },
    notify:     { title: "NOTIFY",      badge: "teal" },
    send:       { title: "SEND",        badge: "teal" },
    observe:    { title: "OBSERVE",     badge: "teal" },
    cancel:     { title: "CANCEL",      badge: "" },
    request:    { title: "REQUEST",     badge: "purple" },
  };

  function describe(e) {
    switch (e.event) {
      case "register":   return `${e.endpoint_name} → ${e.registration_id} (${e.lifetime}s)`;
      case "update":     return `${e.registration_id} lifetime=${e.lifetime}s`;
      case "deregister": return `${e.registration_id}`;
      case "expire":     return `${e.endpoint_name || e.registration_id} after ${e.lifetime}s`;
      case "notify":     return `seq=${e.observe_seq} ` + readings(e.readings);
      case "send":       return `${e.peer || ""} ` + readings(e.readings);
      case "observe":    return (e.paths || []).join(", ");
      case "cancel":     return (e.paths || []).join(", ");
      case "request":    return `${e.operation} ${e.path} → ${e.status}`;
      default:           return JSON.stringify(e);
    }
  }

  const readings = (rs) => (rs || []).map((r) => `${r.path}=${r.value}`).join(" ");

  function eventRow(e, fresh) {
    const style = EVENT_STYLE[e.event] || { title: e.event.toUpperCase(), badge: "" };
    return el("div", { class: "ev" + (fresh ? " new" : "") },
      el("span", { class: "t", text: e._time || "" }),
      el("div", { class: "body" },
        el("div", { class: "ttl" },
          el("span", { class: "badge " + style.badge, text: style.title })),
        el("div", { class: "det", text: describe(e) })));
  }

  // Prepend one row rather than rebuilding the list. At a notification every couple of seconds
  // and a 300-event buffer, a full re-render would rebuild hundreds of nodes on every event and
  // reset the log's scroll position while you were reading it.
  function pushEvent(e) {
    S.events.unshift(e);

    const host = $("log");
    if (!S.events.length || host.querySelector(".empty")) clear(host);
    host.insertBefore(eventRow(e, true), host.firstChild);

    while (S.events.length > MAX_EVENTS) {
      S.events.pop();
      if (host.lastChild) host.removeChild(host.lastChild);
    }
  }

  function renderLog() {
    const host = $("log");
    clear(host);

    if (!S.events.length) {
      host.appendChild(el("div", { class: "empty", text: "Waiting for protocol activity…" }));
      return;
    }
    for (const e of S.events) host.appendChild(eventRow(e, false));
  }

  // ── SSE ──────────────────────────────────────────────────────────────────────
  function connect() {
    const source = new EventSource("/api/events");

    source.onopen = () => { S.connected = true; refreshStats(); };

    source.onerror = () => {
      // EventSource reconnects on its own; just reflect the state honestly in the header.
      S.connected = false;
      refreshStats();
    };

    for (const name of Object.keys(EVENT_STYLE)) {
      source.addEventListener(name, (msg) => {
        let payload;
        try { payload = JSON.parse(msg.data); } catch (_e) { return; }
        payload._time = new Date().toLocaleTimeString();
        pushEvent(payload);

        // A notify updates the relation's last value but changes nothing structural, so the
        // observations panel is refreshed and the tree is left alone — its Observe buttons are
        // already in the right state, and redrawing it on every reading is what made the forms
        // unusable. Observe and cancel do flip a button, so those redraw the tree.
        if (["register", "update", "deregister", "expire"].includes(payload.event)) refresh();

        if (["notify", "observe", "cancel"].includes(payload.event)) {
          const structural = payload.event !== "notify";

          loadObservations()
            .then((o) => {
              S.observations = o;
              renderObservations();
              if (structural) renderTreeIfIdle();
            })
            .catch(() => {});
        }
        refreshStats();
      });
    }
  }

  // ── Boot ─────────────────────────────────────────────────────────────────────
  $("clear-log").addEventListener("click", () => { S.events = []; renderLog(); });

  refresh().then(refreshStats);
  connect();
  // A slow poll as a safety net: `expires_in` counts down continuously, and it also covers the
  // window where the SSE connection is down.
  setInterval(() => { refresh(); refreshStats(); }, 5000);
  </script>
  </body>
  </html>
  """

  @doc """
  The complete page: markup, styles, and script in one string.

  Held in a module attribute, so serving it is a constant-time send with no per-request work.
  """
  @spec page() :: String.t()
  def page, do: @page
end
