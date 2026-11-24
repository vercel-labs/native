// The inspector's own page, served by compiler/inspect.ts. It is one string so a checkout's
// inspector works without reading files beside the compiler.

export const INSPECT_HTML = String.raw`<!doctype html>
<html>
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Native SDK inspector</title>
<style>
  :root {
    color-scheme: dark;
    --bg: #1e1f22; --panel: #26282c; --panel2: #2d3035; --line: #3a3d43;
    --text: #d7d9de; --dim: #93979f; --accent: #67a7ff; --accent2: #1e88e5;
    --tag: #e5a06a; --string: #9acd8b; --number: #d6a2e8; --error: #ff7b72;
  }
  * { box-sizing: border-box; }
  html, body { height: 100%; margin: 0; }
  body { background: var(--bg); color: var(--text); font: 12px/1.45 -apple-system, BlinkMacSystemFont, "SF Pro Text", Segoe UI, sans-serif; overflow: hidden; }
  #app { display: grid; grid-template-rows: 36px minmax(0, 1fr) 190px; height: 100%; }
  header { display: flex; align-items: center; gap: 10px; padding: 0 12px; background: var(--panel); border-bottom: 1px solid var(--line); }
  header .mark { color: var(--accent); font-weight: 600; }
  header .title { color: var(--dim); overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
  header .grow { flex: 1; }
  header .status { color: var(--dim); }
  header .status.on { color: var(--string); }
  button, input[type=text] { background: var(--panel2); color: var(--text); border: 1px solid var(--line); border-radius: 5px; padding: 4px 8px; font: inherit; }
  button:hover { border-color: var(--accent); }
  button.on { border-color: var(--accent); color: var(--accent); }
  main { display: grid; grid-template-columns: minmax(260px, 38%) minmax(0, 1fr); min-height: 0; }
  #tree { overflow: auto; padding: 6px 0 18px; border-right: 1px solid var(--line); background: var(--bg); }
  #detail { display: grid; grid-template-rows: 30px minmax(0, 1fr); min-height: 0; }
  nav { display: flex; gap: 2px; padding: 3px 6px 0; background: var(--panel); border-bottom: 1px solid var(--line); }
  nav button { border: 0; border-bottom: 2px solid transparent; border-radius: 0; background: transparent; color: var(--dim); padding: 5px 10px; }
  nav button.on { color: var(--text); border-bottom-color: var(--accent); background: transparent; }
  #panel { overflow: auto; padding: 10px 14px 24px; }
  .row { display: flex; align-items: center; gap: 4px; height: 20px; padding-right: 8px; white-space: pre; cursor: default; }
  .row:hover { background: #2b2e33; }
  .row.sel { background: #21446e; }
  .row .twist { width: 12px; color: var(--dim); cursor: pointer; text-align: center; }
  .row .tag { color: var(--tag); }
  .row .attr { color: var(--dim); }
  .row .txt { color: var(--string); overflow: hidden; text-overflow: ellipsis; }
  .indent { flex: none; }
  #console { display: grid; grid-template-rows: 26px minmax(0, 1fr) 28px; background: var(--panel); border-top: 1px solid var(--line); min-height: 0; }
  #console .bar { display: flex; align-items: center; gap: 10px; padding: 0 10px; border-bottom: 1px solid var(--line); color: var(--dim); }
  #console .bar .grow { flex: 1; }
  #log { overflow: auto; padding: 4px 10px; font-family: ui-monospace, SFMono-Regular, Menlo, monospace; font-size: 11.5px; }
  #log .line { white-space: pre-wrap; border-bottom: 1px solid #292b2f; padding: 2px 0; }
  #log .line.error { color: var(--error); }
  #log .line.in { color: var(--accent); }
  #log .line.out { color: var(--dim); }
  #prompt { display: flex; align-items: center; gap: 6px; padding: 2px 8px; }
  #prompt span { color: var(--accent); }
  #prompt input { flex: 1; border-color: transparent; background: transparent; outline: none; padding-left: 0; font-family: ui-monospace, SFMono-Regular, Menlo, monospace; }
  table { border-collapse: collapse; width: 100%; }
  th, td { text-align: left; padding: 3px 8px; border-bottom: 1px solid var(--line); font-weight: 400; }
  th { color: var(--dim); position: sticky; top: 0; background: var(--bg); }
  td.num { text-align: right; font-variant-numeric: tabular-nums; }
  .prop { display: grid; grid-template-columns: minmax(150px, 40%) 1fr; gap: 0 12px; }
  .prop div { padding: 2px 0; border-bottom: 1px solid #2a2c31; overflow-wrap: anywhere; }
  .prop .name { color: var(--dim); }
  .k { color: var(--dim); }
  .v { color: var(--text); }
  .sel-head { margin: 0 0 8px; font-size: 13px; color: var(--accent); }
  .muted { color: var(--dim); }
  .box { position: relative; margin: 6px 0 18px; }
  .box div { border: 1px solid; padding: 14px 0 0 14px; }
  .box .m { border-color: #8a6d3b; background: #8a6d3b22; }
  .box .b { border-color: #b5a642; background: #b5a64222; }
  .box .p { border-color: #4f8a4f; background: #4f8a4f22; }
  .box .c { border-color: #4f74a8; background: #4f74a822; min-height: 24px; }
  .box span { position: absolute; font-size: 10px; color: var(--dim); transform: translate(-50%, -50%); background: var(--bg); padding: 0 3px; }
  #drop { color: var(--dim); padding: 30px; text-align: center; }
  .pill { border: 1px solid var(--line); border-radius: 10px; padding: 0 7px; color: var(--dim); }
  .layer { display: grid; grid-template-columns: 1fr 110px 60px; gap: 10px; padding: 3px 0; border-bottom: 1px solid #2a2c31; }
  .layer .name { overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
  .layer .why { color: var(--dim); }
  code { font-family: ui-monospace, SFMono-Regular, Menlo, monospace; }
</style>
</head>
<body>
<div id="app">
  <header>
    <span class="mark">&#9670; Native SDK</span>
    <span class="title" id="title">inspector</span>
    <span class="pill" id="count">0 nodes</span>
    <span class="grow"></span>
    <label class="muted"><input type="checkbox" id="live" checked> live</label>
    <button id="refresh">Refresh</button>
    <span class="status" id="status">connecting</span>
  </header>
  <main>
    <section id="tree"><div id="drop">connecting to the app&hellip;</div></section>
    <section id="detail">
      <nav>
        <button data-tab="styles" class="on">Styles</button>
        <button data-tab="box">Box model</button>
        <button data-tab="layers">Layers</button>
        <button data-tab="frames">Frames</button>
      </nav>
      <div id="panel"><div class="muted">Select a node.</div></div>
    </section>
  </main>
  <footer id="console">
    <div class="bar"><span>Console</span><span class="muted">expressions read the last snapshot</span><span class="grow"></span><button id="clear-log">Clear</button></div>
    <div id="log"></div>
    <div id="prompt"><span>&gt;</span><input id="input" type="text" placeholder="document.querySelector('button').textContent" autocomplete="off" spellcheck="false"></div>
  </footer>
</div>
<script>
(function () {
  'use strict';
  var state = { snap: null, selected: 0, tab: 'styles', collapsed: new Set(), filter: '', ws: null, nextId: 1, waiting: new Map() };
  var treeEl = document.getElementById('tree');
  var panelEl = document.getElementById('panel');
  var logEl = document.getElementById('log');
  var titleEl = document.getElementById('title');
  var countEl = document.getElementById('count');
  var statusEl = document.getElementById('status');

  function el(tag, cls, text) {
    var node = document.createElement(tag);
    if (cls) node.className = cls;
    if (text !== undefined) node.textContent = text;
    return node;
  }

  function send(method, params) {
    if (!state.ws || state.ws.readyState !== 1) return Promise.reject(new Error('not connected'));
    var id = state.nextId++;
    state.ws.send(JSON.stringify({ id: id, method: method, params: params || {} }));
    return new Promise(function (resolve, reject) {
      state.waiting.set(id, { resolve: resolve, reject: reject, method: method });
    });
  }

  function connect() {
    var ws = new WebSocket('ws://' + location.host + '/devtools/page/native');
    state.ws = ws;
    ws.onopen = function () {
      statusEl.textContent = 'connected';
      statusEl.className = 'status on';
      send('Runtime.enable').catch(function () {});
      refresh(true);
    };
    ws.onclose = function () {
      statusEl.textContent = 'disconnected';
      statusEl.className = 'status';
      setTimeout(connect, 1200);
    };
    ws.onmessage = function (event) {
      var message = JSON.parse(event.data);
      if (message.id && state.waiting.has(message.id)) {
        var pending = state.waiting.get(message.id);
        state.waiting.delete(message.id);
        if (message.error) pending.reject(new Error(message.error.message));
        else pending.resolve(message.result);
        return;
      }
      if (message.method === 'Runtime.consoleAPICalled') {
        var a = message.params.args || [];
        log(message.params.type === 'error' ? 'error' : 'out', a.map(function (x) { return x.value !== undefined ? String(x.value) : x.description || ''; }).join(' '));
      } else if (message.method === 'Runtime.exceptionThrown') {
        log('error', message.params.exceptionDetails.text || 'exception');
      } else if (message.method === 'Log.entryAdded') {
        log(message.params.entry.level === 'error' ? 'error' : 'out', message.params.entry.text);
      }
    };
  }

  function refresh(force) {
    return send('Native.getSnapshot').then(function (snap) {
      state.snap = snap;
      titleEl.textContent = snap.title || 'untitled';
      countEl.textContent = snap.nodes.length + ' nodes';
      renderTree();
      renderPanel();
    }).catch(function (err) {
      if (force) {
        treeEl.textContent = '';
        treeEl.appendChild(el('div', 'muted', err.message));
      }
    });
  }

  function byId(id) {
    if (!state.snap) return null;
    for (var i = 0; i < state.snap.nodes.length; i++) if (state.snap.nodes[i].id === id) return state.snap.nodes[i];
    return null;
  }

  function childrenOf(node) {
    if (!state.snap) return [];
    var out = [];
    for (var i = 0; i < state.snap.nodes.length; i++) {
      var n = state.snap.nodes[i];
      if (n.parent === node.id && n.id !== node.id) out.push(n);
    }
    return out;
  }

  function labelOf(node) {
    if (node.pseudo) return node.pseudo;
    if (node.type === 3) return node.text ? '"' + node.text.replace(/\s+/g, ' ').slice(0, 60) + '"' : '""';
    if (node.type === 10) return '<!doctype ' + (node.text || 'html') + '>';
    if (node.type === 8) return '<!--' + node.text.slice(0, 40) + '-->';
    var s = node.name;
    for (var i = 0; i < node.attrs.length; i++) {
      var name = node.attrs[i][0], value = node.attrs[i][1];
      if (name === 'id') s += '#' + value;
      else if (name === 'class') s += '.' + value.trim().split(/\s+/).join('.');
    }
    return s;
  }

  function renderTree() {
    treeEl.textContent = '';
    if (!state.snap) return;
    var root = byId(state.snap.root);
    if (!root) { treeEl.appendChild(el('div', 'muted', 'the page has no root')); return; }
    var frag = document.createDocumentFragment();
    var walk = function (node, depth) {
      var row = el('div', 'row' + (node.id === state.selected ? ' sel' : ''));
      row.dataset.id = String(node.id);
      var indent = el('span', 'indent');
      indent.style.width = (depth * 12) + 'px';
      row.appendChild(indent);
      var kids = childrenOf(node);
      var twist = el('span', 'twist', kids.length === 0 ? '' : (state.collapsed.has(node.id) ? '▸' : '▾'));
      twist.onclick = function (event) {
        event.stopPropagation();
        if (state.collapsed.has(node.id)) state.collapsed.delete(node.id); else state.collapsed.add(node.id);
        renderTree();
      };
      row.appendChild(twist);
      if (node.type === 1) {
        row.appendChild(el('span', 'tag', labelOf(node)));
      } else if (node.pseudo) {
        row.appendChild(el('span', 'tag', node.pseudo));
      } else {
        row.appendChild(el('span', 'txt', labelOf(node)));
      }
      row.onclick = function () { select(node.id); };
      row.onmouseenter = function () { send('Overlay.highlightNode', { nodeId: node.id }).catch(function () {}); };
      row.onmouseleave = function () { send('Overlay.hideHighlight').catch(function () {}); };
      frag.appendChild(row);
      if (!state.collapsed.has(node.id)) for (var i = 0; i < kids.length; i++) walk(kids[i], depth + 1);
    };
    walk(root, 0);
    treeEl.appendChild(frag);
    var selectedRow = treeEl.querySelector('.row.sel');
    if (selectedRow) selectedRow.scrollIntoView({ block: 'nearest' });
  }

  function select(id) {
    state.selected = id;
    renderTree();
    renderPanel();
    send('Overlay.highlightNode', { nodeId: id }).catch(function () {});
  }

  function section(title) {
    return el('h3', 'sel-head', title);
  }

  function renderPanel() {
    var node = byId(state.selected);
    panelEl.textContent = '';
    if (state.tab === 'layers') return renderLayers();
    if (state.tab === 'frames') return renderFrames();
    if (!node) { panelEl.appendChild(el('div', 'muted', 'Select a node in the tree.')); return; }
    if (state.tab === 'box') return renderBox(node);
    renderStyles(node);
  }

  function renderStyles(node) {
    var head = labelOf(node);
    panelEl.appendChild(el('div', 'sel-head', head));
    if (node.attrs.length) {
      var attrs = el('div', 'prop');
      for (var i = 0; i < node.attrs.length; i++) {
        attrs.appendChild(el('div', 'name', node.attrs[i][0]));
        attrs.appendChild(el('div', 'v', node.attrs[i][1]));
      }
      panelEl.appendChild(attrs);
      panelEl.appendChild(el('div', 'muted', ' '));
    }
    var filter = el('input', '', '');
    filter.type = 'text';
    filter.placeholder = 'filter properties';
    filter.value = state.filter;
    filter.style.margin = '6px 0';
    filter.oninput = function () { state.filter = filter.value; renderPanel(); };
    panelEl.appendChild(filter);
    var props = el('div', 'prop');
    var names = Object.keys(node.styles);
    for (var j = 0; j < names.length; j++) {
      var name = names[j];
      var value = node.styles[name];
      if (!value) continue;
      if (state.filter && name.indexOf(state.filter) < 0 && value.indexOf(state.filter) < 0) continue;
      props.appendChild(el('div', 'name', name));
      props.appendChild(el('div', 'v', value));
    }
    panelEl.appendChild(props);
  }

  function renderBox(node) {
    panelEl.appendChild(el('div', 'sel-head', labelOf(node)));
    if (!node.box || !node.rect) { panelEl.appendChild(el('div', 'muted', 'This node has no box.')); return; }
    var b = node.box;
    var box = el('div', 'box');
    var margin = el('div', 'm');
    margin.appendChild(el('span', '', String(b.margin[0]) + ' ' + String(b.margin[1]) + ' ' + String(b.margin[2]) + ' ' + String(b.margin[3])));
    var border = el('div', 'b');
    border.appendChild(el('span', '', 'border ' + b.border.join(' ')));
    var padding = el('div', 'p');
    padding.appendChild(el('span', '', 'padding ' + b.padding.join(' ')));
    var content = el('div', 'c');
    content.appendChild(el('span', '', Math.round(node.rect[2]) + ' x ' + Math.round(node.rect[3])));
    padding.appendChild(content);
    border.appendChild(padding);
    margin.appendChild(border);
    box.appendChild(margin);
    panelEl.appendChild(box);
    var rows = [
      ['content', node.rect[2] + ' x ' + node.rect[3]],
      ['position', Math.round(node.rect[0]) + ', ' + Math.round(node.rect[1])],
      ['scroll', node.scroll ? node.scroll.left + ', ' + node.scroll.top : '-'],
      ['scroll size', node.scroll ? node.scroll.width + ' x ' + node.scroll.height : '-'],
      ['client size', node.scroll ? node.scroll.clientWidth + ' x ' + node.scroll.clientHeight : '-'],
    ];
    var table = el('div', 'prop');
    for (var i = 0; i < rows.length; i++) { table.appendChild(el('div', 'name', rows[i][0])); table.appendChild(el('div', 'v', rows[i][1])); }
    panelEl.appendChild(table);
  }

  function renderLayers() {
    if (!state.snap) return;
    panelEl.appendChild(el('div', 'sel-head', state.snap.layers.length + ' layers'));
    var head = el('div', 'layer');
    head.appendChild(el('div', 'muted', 'element'));
    head.appendChild(el('div', 'muted', 'reason'));
    head.appendChild(el('div', 'muted', 'z-index'));
    panelEl.appendChild(head);
    for (var i = 0; i < state.snap.layers.length; i++) {
      var layer = state.snap.layers[i];
      var row = el('div', 'layer');
      var name = el('div', 'name', new Array(layer.depth + 1).join('  ') + layer.name);
      name.onclick = function (id) { return function () { select(id); }; }(layer.id);
      row.appendChild(name);
      row.appendChild(el('div', 'why', layer.reason));
      row.appendChild(el('div', 'v', String(layer.zIndex)));
      panelEl.appendChild(row);
    }
  }

  function renderFrames() {
    if (!state.snap) return;
    var frames = state.snap.frames.slice(-60).reverse();
    panelEl.appendChild(el('div', 'sel-head', 'Frame timings (ms)'));
    var table = el('table');
    var head = el('tr');
    ['frame', 'style', 'anim', 'layout', 'paint', 'total'].forEach(function (name) { head.appendChild(el('th', '', name)); });
    table.appendChild(head);
    for (var i = 0; i < frames.length; i++) {
      var f = frames[i];
      var tr = el('tr');
      [f.frame, f.style, f.anim, f.layout, f.paint, f.total].forEach(function (v) {
        tr.appendChild(el('td', 'num', typeof v === 'number' ? (Math.round(v * 100) / 100).toString() : String(v)));
      });
      table.appendChild(tr);
    }
    panelEl.appendChild(table);
    panelEl.appendChild(el('div', 'muted', 'The runtime measures every frame while the inspector is on; NATIVE_FRAME_TIMES also prints them.'));
  }

  function log(kind, text) {
    var line = el('div', 'line ' + kind, text);
    logEl.appendChild(line);
    logEl.scrollTop = logEl.scrollHeight;
  }

  document.getElementById('refresh').onclick = function () { refresh(true); };
  document.getElementById('clear-log').onclick = function () { logEl.textContent = ''; send('Log.clear').catch(function () {}); };
  document.getElementById('input').addEventListener('keydown', function (event) {
    if (event.key !== 'Enter') return;
    var expression = event.target.value;
    if (!expression) return;
    event.target.value = '';
    log('in', '> ' + expression);
    send('Runtime.evaluate', { expression: expression, returnByValue: true }).then(function (result) {
      if (result.exceptionDetails) log('error', result.exceptionDetails.text);
      else log('out', result.result && result.result.value !== undefined ? JSON.stringify(result.result.value) : String(result.result && result.result.description || 'undefined'));
    }).catch(function (err) { log('error', err.message); });
  });
  var tabs = document.querySelectorAll('nav button');
  for (var t = 0; t < tabs.length; t++) {
    tabs[t].onclick = function (event) {
      state.tab = event.target.dataset.tab;
      for (var k = 0; k < tabs.length; k++) tabs[k].className = tabs[k] === event.target ? 'on' : '';
      renderPanel();
    };
  }
  var live = document.getElementById('live');
  setInterval(function () { if (live.checked && state.ws && state.ws.readyState === 1) refresh(false); }, 1500);

  connect();
})();
</script>
</body>
</html>`;
