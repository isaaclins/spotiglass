(() => {
  "use strict";
  const doc = document.documentElement;
  doc.classList.add("js");
  const reduce = matchMedia("(prefers-reduced-motion: reduce)").matches;
  const touch = matchMedia("(hover: none) and (pointer: coarse)").matches;
  if (touch) doc.classList.add("is-touch");
  const qs = new URLSearchParams(location.search);
  if (qs.get("accent")) doc.dataset.accent = qs.get("accent");
  const win = document.querySelector(".hero .window");
  if (qs.get("win") === "dark") win.querySelectorAll("img").forEach((im, i) => { if (i) im.remove(); else { im.src = "screens/home-2200.webp"; im.removeAttribute("srcset"); } });
  else if (qs.get("win") !== "print") setTimeout(() => win.classList.add("developed"), reduce ? 0 : 2600);
  const isMac = /Mac|iPhone|iPad/.test(navigator.platform || navigator.userAgent);

  /* ---------- bar ---------- */
  const bar = document.getElementById("bar");
  const onScroll = () => bar.classList.toggle("is-scrolled", scrollY > 8);
  addEventListener("scroll", onScroll, { passive: true });
  onScroll();

  /* ---------- latest release ---------- */
  const REPO = "isaaclins/spotiglass";
  fetch(`https://api.github.com/repos/${REPO}/releases/latest`, { headers: { Accept: "application/vnd.github+json" } })
    .then(r => (r.ok ? r.json() : Promise.reject(r.status)))
    .then(rel => {
      const dmg = (rel.assets || []).find(a => /\.dmg$/i.test(a.name));
      if (dmg) document.querySelectorAll("[data-dl]").forEach(a => (a.href = dmg.browser_download_url));
      const v = String(rel.tag_name || "").replace(/^v/i, "");
      if (v) document.querySelectorAll("[data-ver]").forEach(el => (el.textContent = `Version ${v}`));
    })
    .catch(() => {});

  /* ---------- palette data (the app's screenshot-mode sample library) ---------- */
  const A = n => `screens/art-${n}.webp`;
  const ITEMS = [
    { k: "song", t: "Midnight City", s: "M83", art: A("m83b") },
    { k: "song", t: "Nightcall", s: "Kavinsky", art: A("kavinsky") },
    { k: "song", t: "Kerala", s: "Bonobo", art: A("migration") },
    { k: "song", t: "Awake", s: "Tycho", art: A("awake") },
    { k: "song", t: "A Moment Apart", s: "ODESZA", art: A("moment") },
    { k: "song", t: "LesAlpx", s: "Floating Points", art: A("lesalpx") },
    { k: "song", t: "Emerald Rush", s: "Jon Hopkins", art: A("singularity") },
    { k: "song", t: "Baby", s: "Four Tet", art: A("baby") },
    { k: "song", t: "Persona", s: "Rival Consoles" },
    { k: "artist", t: "Bonobo", s: "Artist" },
    { k: "artist", t: "Tycho", s: "Artist" },
    { k: "artist", t: "Jon Hopkins", s: "Artist" },
    { k: "artist", t: "Kavinsky", s: "Artist" },
    { k: "artist", t: "M83", s: "Artist" },
    { k: "artist", t: "Floating Points", s: "Artist" },
    { k: "artist", t: "Four Tet", s: "Artist" },
    { k: "artist", t: "ODESZA", s: "Artist" },
    { k: "artist", t: "Burial", s: "Artist" },
    { k: "album", t: "Migration", s: "Bonobo" },
    { k: "album", t: "Awake", s: "Tycho" },
    { k: "album", t: "Singularity", s: "Jon Hopkins" },
    { k: "album", t: "Nightcall", s: "Kavinsky" },
    { k: "album", t: "A Moment Apart", s: "ODESZA" },
    { k: "album", t: "Persona", s: "Rival Consoles" },
    { k: "playlist", t: "Night Drive", s: "Playlist" },
    { k: "playlist", t: "Late Night Coding", s: "Playlist" },
    { k: "playlist", t: "Deep Focus", s: "Playlist" },
    { k: "playlist", t: "Sunday Reset", s: "Playlist" },
    { k: "playlist", t: "Gym", s: "Playlist" },
    { k: "playlist", t: "Liked Songs", s: "Playlist" },
    { k: "cmd", t: "Toggle Play/Pause", s: "Pause or resume playback", id: "play" },
    { k: "cmd", t: "Next Track", s: "Skip to the next track", id: "next" },
    { k: "cmd", t: "Previous Track", s: "Return to the previous track", id: "prev" },
    { k: "cmd", t: "Toggle Queue", s: "Show or hide the playback queue panel", id: "queue" },
    { k: "cmd", t: "Toggle Lyrics", s: "Show or hide immersive synchronized lyrics", id: "lyrics" },
    { k: "cmd", t: "Pop Out Lyrics", s: "Open the lyrics in a small window that can stay on top", id: "popout" },
  ];
  const SECTIONS = [["song", "Songs"], ["artist", "Artists"], ["album", "Albums"], ["playlist", "Playlists"]];
  const pinned = new Set();
  const state = { playing: true, queue: false, lyrics: false };

  const ICONS = {
    artist: '<svg viewBox="0 0 20 20" width="18" height="18"><circle cx="10" cy="7" r="3.4" fill="none" stroke="currentColor" stroke-width="1.5"/><path d="M3.5 17c1-3.3 3.5-5 6.5-5s5.5 1.7 6.5 5" fill="none" stroke="currentColor" stroke-width="1.5" stroke-linecap="round"/></svg>',
    album: '<svg viewBox="0 0 20 20" width="19" height="19"><circle cx="10" cy="10" r="7.6" fill="none" stroke="currentColor" stroke-width="1.5"/><circle cx="10" cy="10" r="2.2" fill="none" stroke="currentColor" stroke-width="1.5"/><path d="M5.6 8.2a4.8 4.8 0 0 1 2.6-2.6" fill="none" stroke="currentColor" stroke-width="1.3" stroke-linecap="round"/></svg>',
    playlist: '<svg viewBox="0 0 20 20" width="19" height="19"><path d="M3 5h8M3 9h8M3 13h5" stroke="currentColor" stroke-width="1.5" stroke-linecap="round"/><path d="M14 4v9.2" stroke="currentColor" stroke-width="1.5" stroke-linecap="round"/><path d="M14 4l3.5-1" stroke="currentColor" stroke-width="1.5" stroke-linecap="round"/><circle cx="12.4" cy="14" r="1.9" fill="currentColor"/></svg>',
    cmd: '<svg viewBox="0 0 20 20" width="18" height="18"><path d="M5 8.5L7.8 11 5 13.5M10 14h5" fill="none" stroke="currentColor" stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round"/><rect x="2.5" y="3.5" width="15" height="13" rx="3" fill="none" stroke="currentColor" stroke-width="1.5"/></svg>',
    song: '<svg viewBox="0 0 20 20" width="18" height="18"><path d="M8 15V4.5l8-1.5v10" fill="none" stroke="currentColor" stroke-width="1.5" stroke-linejoin="round"/><circle cx="6" cy="15" r="2" fill="currentColor"/><circle cx="14" cy="13" r="2" fill="currentColor"/></svg>',
  };
  const PIN = '<svg class="pin" viewBox="0 0 16 16" width="13" height="13"><path d="M10.2 1.5l4.3 4.3-1.6.6-2.6 2.6.3 3.2-1.2 1.2-2.8-2.8-3.5 3.5-.7-.7 3.5-3.5L3.1 7.1l1.2-1.2 3.2.3 2.6-2.6z" fill="currentColor"/></svg>';
  const QUEUE = '<svg viewBox="0 0 16 16" width="13" height="13"><path d="M2 4h9M2 8h9M2 12h5M12 10v5M9.5 12.5h5" stroke="currentColor" stroke-width="1.4" stroke-linecap="round"/></svg>';
  const esc = s => s.replace(/[&<>"]/g, c => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;" }[c]));

  function results(q) {
    const raw = q.trim();
    if (raw.startsWith(">")) {
      const cq = raw.slice(1).trim().toLowerCase();
      const cmds = ITEMS.filter(i => i.k === "cmd" && (!cq || i.t.toLowerCase().includes(cq) || i.s.toLowerCase().includes(cq)));
      return cmds.length ? [["Commands", cmds]] : [];
    }
    const lq = raw.toLowerCase();
    if (!lq) {
      return [
        ["Quick actions", ITEMS.filter(i => i.k === "cmd").slice(0, 3)],
        ["My Playlists", ITEMS.filter(i => i.k === "playlist")],
      ];
    }
    const out = [];
    for (const [k, label] of SECTIONS) {
      const hits = ITEMS.filter(i => i.k === k && (i.t.toLowerCase().includes(lq) || (k !== "artist" && k !== "playlist" && i.s.toLowerCase().includes(lq))));
      // titles that start with the query first
      hits.sort((a, b) => (b.t.toLowerCase().startsWith(lq) - a.t.toLowerCase().startsWith(lq)));
      if (hits.length) out.push([label, hits.slice(0, k === "song" ? 3 : 2)]);
    }
    return out;
  }

  /* ---------- palette component ---------- */
  const tpl = document.getElementById("palette-tpl");
  const palettes = [];
  function Palette(slot, opts = {}) {
    const root = tpl.content.firstElementChild.cloneNode(true);
    slot.appendChild(root);
    const input = root.querySelector(".pal-input");
    const list = root.querySelector(".pal-list");
    const foot = root.querySelector(".pal-foot");
    const status = root.querySelector(".pal-status");
    const uid = Math.random().toString(36).slice(2, 7);
    list.id = `pal-list-${uid}`;
    input.setAttribute("aria-controls", list.id);
    let flat = [];
    let sel = 0;
    let statusTimer = 0;

    function render() {
      const groups = results(input.value);
      flat = [];
      list.innerHTML = "";
      if (!groups.length) {
        list.innerHTML = '<div class="pal-empty">No results</div>';
        input.removeAttribute("aria-activedescendant");
        return;
      }
      for (const [label, items] of groups) {
        const h = document.createElement("div");
        h.className = "pal-sec";
        h.textContent = label;
        h.setAttribute("role", "presentation");
        list.appendChild(h);
        for (const it of items) {
          const idx = flat.length;
          const row = document.createElement("div");
          row.className = "pal-row";
          row.id = `pal-${uid}-${idx}`;
          row.setAttribute("role", "option");
          const key = it.k + ":" + it.t;
          const media = it.art ? `<img class="pal-art" src="${it.art}" alt="" width="36" height="36" loading="lazy">` : `<span class="pal-ico" aria-hidden="true">${ICONS[it.k]}</span>`;
          row.innerHTML = `${media}<span class="pal-txt"><span class="pal-t">${esc(it.t)}</span><span class="pal-s">${esc(it.s)}</span></span><span class="pal-tag" aria-hidden="true">${pinned.has(key) ? PIN : ""}</span>`;
          row.addEventListener("pointermove", () => { if (sel !== idx) select(idx, false); });
          row.addEventListener("click", e => { select(idx, false); act(e.shiftKey ? "queue" : (e.metaKey || e.ctrlKey) ? "pin" : "run"); });
          list.appendChild(row);
          flat.push({ it, row, key });
        }
      }
      select(Math.min(sel, flat.length - 1), false);
    }

    function select(i, scroll = true) {
      if (!flat.length) return;
      sel = (i + flat.length) % flat.length;
      flat.forEach((f, j) => f.row.setAttribute("aria-selected", j === sel ? "true" : "false"));
      input.setAttribute("aria-activedescendant", flat[sel].row.id);
      if (scroll) {
        const r = flat[sel].row;
        const top = r.offsetTop - list.offsetTop;
        if (top < list.scrollTop + 4) list.scrollTop = Math.max(0, top - 30);
        else if (top + r.offsetHeight > list.scrollTop + list.clientHeight) list.scrollTop = top + r.offsetHeight - list.clientHeight + 4;
      }
    }

    function say(html) {
      status.innerHTML = html;
      foot.classList.add("has-status");
      clearTimeout(statusTimer);
      statusTimer = setTimeout(() => foot.classList.remove("has-status"), 1900);
    }
    function pulse(row, cls) {
      row.classList.remove("flash", "nudge");
      void row.offsetWidth;
      row.classList.add(cls);
      setTimeout(() => row.classList.remove(cls), 600);
    }

    function act(kind) {
      const f = flat[sel];
      if (!f) return;
      const { it, row, key } = f;
      const name = `<b>${esc(it.t)}</b>`;
      if (kind === "run") {
        pulse(row, "flash");
        if (it.k === "song") { state.playing = true; say(`<span class="dot"></span>Playing ${name} · ${esc(it.s)}`); }
        else if (it.k === "cmd") {
          const msg = {
            play: () => ((state.playing = !state.playing) ? "Playing" : "Paused"),
            next: () => "Next track",
            prev: () => "Previous track",
            queue: () => ((state.queue = !state.queue) ? "Queue shown" : "Queue hidden"),
            lyrics: () => ((state.lyrics = !state.lyrics) ? "Lyrics shown" : "Lyrics hidden"),
            popout: () => "Lyrics popped out",
          }[it.id]();
          say(`<span class="dot"></span>${msg}`);
        } else say(`Opened ${name}`);
      } else if (kind === "queue") {
        if (it.k === "song" || it.k === "album" || it.k === "playlist") {
          pulse(row, "flash");
          const tag = row.querySelector(".pal-tag");
          let q = tag.querySelector(".qmark");
          if (!q) { tag.insertAdjacentHTML("afterbegin", `<span class="qmark">${QUEUE}</span>`); q = tag.querySelector(".qmark"); }
          clearTimeout(q._t);
          q._t = setTimeout(() => q.remove(), 1900);
          say(`${QUEUE} Added ${name} to the queue`);
        } else pulse(row, "nudge");
      } else if (kind === "pin") {
        if (it.k === "cmd") return pulse(row, "nudge");
        const was = pinned.has(key);
        if (was) pinned.delete(key); else pinned.add(key);
        palettes.forEach(p => p.render());
        pulse(flat[sel].row, "flash");
        say(was ? `Unpinned ${name}` : `${PIN} Pinned ${name} to the sidebar`);
      }
    }

    input.addEventListener("input", () => { sel = 0; list.scrollTop = 0; render(); });
    input.addEventListener("keydown", e => {
      if (e.key === "ArrowDown") { e.preventDefault(); select(sel + 1); }
      else if (e.key === "ArrowUp") { e.preventDefault(); select(sel - 1); }
      else if (e.key === "Enter") { e.preventDefault(); act(e.shiftKey ? "queue" : (e.metaKey || e.ctrlKey) ? "pin" : "run"); }
      else if (e.key === "Escape") {
        if (opts.onEscape) return;
        e.preventDefault();
        if (input.value) { input.value = ""; sel = 0; render(); }
        else input.blur();
      }
    });
    root.querySelectorAll("button.hint").forEach(b => b.addEventListener("click", () => act(b.dataset.act)));
    input.placeholder = "Search Spotify";
    render();
    const api = { root, input, render, select, act, get sel() { return sel; } };
    palettes.push(api);
    return api;
  }

  /* ---------- inline palette with self-typing demo ---------- */
  const inline = Palette(document.getElementById("inline-slot"));
  let demoOn = !reduce;
  const stopDemo = () => { demoOn = false; };
  ["pointerdown", "focus", "keydown", "wheel"].forEach(ev => inline.root.addEventListener(ev, stopDemo, { passive: true, capture: true }));

  const sleep = ms => new Promise(r => setTimeout(r, ms));
  let inView = false;
  const waitView = async () => { while (!inView) await sleep(250); };
  const SCRIPT = [
    { q: "awake", moves: 0, act: "queue" },
    { q: "bonobo", moves: 0, act: "run" },
    { q: "> lyr", moves: 0, act: "run" },
    { q: "deep", moves: 0, act: "pin" },
  ];
  async function typeTo(text) {
    const inp = inline.input;
    while (inp.value.length) {
      if (!demoOn) return false;
      await waitView();
      if (!demoOn) return false;
      inp.value = inp.value.slice(0, -1);
      inp.dispatchEvent(new Event("input"));
      await sleep(38);
    }
    await sleep(260);
    for (const ch of text) {
      if (!demoOn) return false;
      await waitView();
      if (!demoOn) return false;
      inp.value += ch;
      inp.dispatchEvent(new Event("input"));
      await sleep(95 + Math.random() * 90);
    }
    return true;
  }
  async function demo() {
    for (let n = 0; demoOn; n = (n + 1) % SCRIPT.length) {
      const step = SCRIPT[n];
      if (!(await typeTo(step.q))) return;
      await sleep(900);
      if (!demoOn) return;
      for (let m = 0; m < step.moves; m++) { if (!demoOn) return; inline.select(inline.sel + 1); await sleep(520); }
      if (!demoOn) return;
      await sleep(350);
      if (!demoOn) return;
      inline.act(step.act);
      await sleep(2300);
    }
  }
  if (reduce) { inline.input.value = "awake"; inline.render(); }
  const stage = document.querySelector(".stage");
  new IntersectionObserver(es => es.forEach(e => (inView = e.isIntersecting)), { threshold: 0.35 }).observe(stage);
  if (demoOn) demo();

  /* ---------- ⌘K anywhere ---------- */
  const modal = document.getElementById("modal");
  let modalPal = null;
  let lastFocus = null;
  function openModal() {
    if (!modalPal) modalPal = Palette(document.getElementById("modal-slot"), { onEscape: closeModal });
    lastFocus = document.activeElement;
    modal.hidden = false;
    doc.style.overflow = "hidden";
    modalPal.input.value = "";
    modalPal.render();
    modalPal.input.focus();
  }
  function closeModal() {
    modal.hidden = true;
    doc.style.overflow = "";
    if (lastFocus && lastFocus.focus) lastFocus.focus({ preventScroll: true });
  }
  modal.addEventListener("click", e => { if (e.target.closest("[data-close]")) closeModal(); });
  modal.addEventListener("keydown", e => {
    if (e.key === "Escape") { e.preventDefault(); closeModal(); return; }
    if (e.key === "Tab") {
      const f = [...modal.querySelectorAll("input, button")];
      const i = f.indexOf(document.activeElement);
      e.preventDefault();
      f[(i + (e.shiftKey ? -1 : 1) + f.length) % f.length].focus();
    }
  });
  addEventListener("keydown", e => {
    if ((e.metaKey || e.ctrlKey) && !e.altKey && e.key.toLowerCase() === "k") {
      e.preventDefault();
      if (!modal.hidden) return closeModal();
      const r = stage.getBoundingClientRect();
      const visible = Math.min(r.bottom, innerHeight) - Math.max(r.top, 0);
      if (visible > r.height * 0.6) { stopDemo(); inline.input.focus(); inline.input.select(); }
      else openModal();
    }
  });
  if (!isMac) document.querySelectorAll("#search-title kbd").forEach(k => (k.textContent = "Ctrl K"));

  /* ---------- Spotify / Apple Music switch (shown only when both captures exist) ---------- */
  const svcSec = document.getElementById("services");
  const AM = "screens/applemusic-home-2200.webp";
  fetch(AM, { method: "HEAD" }).then(r => {
    if (!r.ok || !/image/.test(r.headers.get("content-type") || "")) return;
    svcSec.querySelector('[data-svc-img="apple"]').src = AM;
    svcSec.hidden = false;
    const seg = svcSec.querySelector(".seg");
    seg.addEventListener("click", e => {
      const b = e.target.closest("button[data-svc]");
      if (!b) return;
      seg.dataset.on = b.dataset.svc;
      seg.querySelectorAll("button").forEach(x => x.setAttribute("aria-checked", String(x === b)));
      svcSec.querySelectorAll("[data-svc-img]").forEach(img => img.classList.toggle("is-off", img.dataset.svcImg !== b.dataset.svc));
    });
  }).catch(() => {});

  /* ---------- the arch, built stone by stone ---------- */
  const svg = document.getElementById("arch");
  const NS = "http://www.w3.org/2000/svg";
  const CX = 1000, CY = 725, RX = 510, RY = 470;
  const P = deg => { const a = (deg * Math.PI) / 180; return [CX - RX * Math.cos(a), CY - RY * Math.sin(a)].map(n => n.toFixed(1)); };
  const rect = (x1, y1, x2, y2) => `M${x1},${y1}H${x2}V${y2}H${x1}Z`;
  const wedge = (a1, a2) => { const [x1, y1] = P(a1), [x2, y2] = P(a2); return `M${CX},${CY}L${x1},${y1}A${RX},${RY} 0 0 1 ${x2},${y2}Z`; };
  const spL = `M300,725L${CX - RX},725A${RX},${RY} 0 0 1 ${CX},${CY - RY}L${CX},250L300,250Z`;
  const spR = `M${CX},250L${CX},${CY - RY}A${RX},${RY} 0 0 1 ${CX + RX},725L1700,725L1700,250Z`;
  const pieces = [];
  const rows = [[1180, 1400], [1040, 1180], [915, 1040], [805, 915], [725, 805]];
  for (const [y1, y2] of rows) { pieces.push([rect(0, y1, 1000, y2)]); pieces.push([rect(1000, y1, 2000, y2)]); }
  const step = 84 / 6;
  for (let i = 0; i < 6; i++) { pieces.push([wedge(i * step, (i + 1) * step)]); pieces.push([wedge(180 - (i + 1) * step, 180 - i * step)]); }
  const KEY = pieces.length;
  const KEYSTONE = "M933,203H1067L1034,428H966Z";
  pieces.push([KEYSTONE]);
  pieces.push([spL, rect(0, 490, 2000, 725)], [spR, rect(0, 490, 2000, 725)], [spL, rect(0, 240, 2000, 490)], [spR, rect(0, 240, 2000, 490)]);
  pieces.push([rect(0, 128, 1000, 250)], [rect(1000, 128, 2000, 250)]);
  pieces.push([rect(0, 0, 683, 128)], [rect(1313, 0, 2000, 128)], [rect(683, 0, 1313, 128)]);

  const narrow = matchMedia("(max-width: 899px)").matches;
  const defs = document.createElementNS(NS, "defs");
  const img = document.createElementNS(NS, "image");
  img.id = "arch-img";
  img.setAttribute("href", narrow ? "img/arch-1100.webp" : "img/arch-2000.webp");
  img.setAttribute("width", "2000");
  img.setAttribute("height", "1400");
  defs.appendChild(img);
  // the keystone is struck in the accent ink, like a wax seal
  defs.insertAdjacentHTML("beforeend", '<filter id="seal" color-interpolation-filters="sRGB"><feColorMatrix type="matrix" values="0 0 0 0 0.91  0 0 0 0 0.32  0 0 0 0 0.17  0 0 0 1 0"/></filter>');
  defs.insertAdjacentHTML("beforeend", `<mask id="nokey" maskUnits="userSpaceOnUse" x="0" y="0" width="2000" height="1400"><rect width="2000" height="1400" fill="#fff"/><path d="${KEYSTONE}" fill="#000"/></mask>`);
  svg.appendChild(defs);
  const masonry = document.createElementNS(NS, "g");
  masonry.setAttribute("mask", "url(#nokey)");
  svg.appendChild(masonry);
  const groups = pieces.map((paths, i) => {
    let parent;
    const g = document.createElementNS(NS, "g");
    g.setAttribute("class", "st");
    (i === KEY ? svg : masonry).appendChild(g);
    parent = g;
    paths.forEach((d, j) => {
      const cp = document.createElementNS(NS, "clipPath");
      cp.id = `c${i}-${j}`;
      const p = document.createElementNS(NS, "path");
      p.setAttribute("d", d);
      cp.appendChild(p);
      defs.appendChild(cp);
      const inner = document.createElementNS(NS, j === paths.length - 1 ? "use" : "g");
      inner.setAttribute("clip-path", `url(#${cp.id})`);
      if (j === paths.length - 1) inner.setAttribute("href", "#arch-img");
      parent.appendChild(inner);
      parent = inner;
    });
    if (i === KEY) g.setAttribute("filter", "url(#seal)");
    return g;
  });

  const gate = document.getElementById("download");
  // The arch builds itself once, just before its section scrolls into view: every stone has its own
  // slice of a 1.4 s timeline, overlapping the next, so it glides together instead of stepping.
  const N = groups.length, SLICE = 0.3, LEAD = (1 - SLICE) / (N - 1), DUR = 1400;
  const ease = t => 1 - Math.pow(1 - t, 3);
  function paint(p) {
    for (let i = 0; i < N; i++) {
      const t = ease(Math.min(1, Math.max(0, (p - i * LEAD) / SLICE)));
      const st = groups[i].style;
      st.opacity = t.toFixed(3);
      st.transform = t >= 1 ? "none" : `translateY(${(-48 * (1 - t)).toFixed(1)}px)`;
    }
  }
  let started = false;
  function play() {
    if (started) return;
    started = true;
    if (reduce) { paint(1); return; }
    const t0 = performance.now();
    const frame = now => { const p = Math.min(1, (now - t0) / DUR); paint(p); if (p < 1) requestAnimationFrame(frame); };
    requestAnimationFrame(frame);
  }
  paint(reduce ? 1 : 0);
  new IntersectionObserver((es, io) => { if (es.some(e => e.isIntersecting)) { play(); io.disconnect(); } },
    { rootMargin: "0px 0px 10% 0px", threshold: 0 }).observe(gate);
})();
