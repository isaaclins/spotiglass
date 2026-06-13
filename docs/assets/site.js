/* =========================================================
   Spotiglass — landing page interactions
   ========================================================= */
(function () {
  "use strict";

  const reduceMotion = window.matchMedia("(prefers-reduced-motion: reduce)").matches;

  /* ---------- always-fresh download link ----------
     Pull the newest .dmg from the GitHub Releases API so the CTA never goes
     stale. If anything fails we keep the hardcoded v0.2.0 link in the HTML. */
  (function freshenDownload() {
    fetch("https://api.github.com/repos/isaaclins/spotiglass/releases/latest", {
      headers: { Accept: "application/vnd.github+json" },
    })
      .then((r) => (r.ok ? r.json() : Promise.reject(r.status)))
      .then((rel) => {
        const dmg = (rel.assets || []).find((a) => /\.dmg$/i.test(a.name));
        if (dmg) {
          document
            .querySelectorAll("a.js-download")
            .forEach((a) => (a.href = dmg.browser_download_url));
        }
        const tag = document.getElementById("verTag");
        if (tag && rel.tag_name) tag.textContent = rel.tag_name;
      })
      .catch(() => {/* keep fallback href */});
  })();

  /* ---------- sticky nav shadow ---------- */
  const nav = document.querySelector(".nav");
  const onScroll = () => nav.classList.toggle("is-stuck", window.scrollY > 12);
  onScroll();
  window.addEventListener("scroll", onScroll, { passive: true });

  /* ---------- scroll reveal ---------- */
  const revealEls = document.querySelectorAll("[data-reveal]");
  if (reduceMotion || !("IntersectionObserver" in window)) {
    revealEls.forEach((el) => el.classList.add("is-in"));
  } else {
    const io = new IntersectionObserver(
      (entries) => {
        entries.forEach((e) => {
          if (e.isIntersecting) {
            e.target.classList.add("is-in");
            io.unobserve(e.target);
          }
        });
      },
      { threshold: 0.12, rootMargin: "0px 0px -8% 0px" }
    );
    revealEls.forEach((el) => io.observe(el));
  }

  /* ---------- hero window parallax ---------- */
  const heroWindow = document.getElementById("heroWindow");
  if (heroWindow && !reduceMotion && window.matchMedia("(pointer:fine)").matches) {
    const stage = heroWindow.closest(".hero__stage");
    let raf = 0;
    stage.addEventListener("mousemove", (e) => {
      const r = stage.getBoundingClientRect();
      const x = (e.clientX - r.left) / r.width - 0.5;
      const y = (e.clientY - r.top) / r.height - 0.5;
      cancelAnimationFrame(raf);
      raf = requestAnimationFrame(() => {
        heroWindow.style.transform = `rotateY(${x * 7}deg) rotateX(${-y * 6}deg)`;
      });
    });
    stage.addEventListener("mouseleave", () => {
      heroWindow.style.transform = "";
    });
  }

  /* =========================================================
     Hero mini-player — play/pause, seek, track switching
     ========================================================= */
  (function heroPlayer() {
    const win = document.getElementById("heroWindow");
    if (!win) return;
    const playBtn = document.getElementById("heroPlay");
    const prog = document.getElementById("heroProg");
    const elapsed = document.getElementById("heroElapsed");
    const seek = document.getElementById("heroSeek");
    const trackEl = document.getElementById("heroTrack");
    const artistEl = document.getElementById("heroArtist");
    const artEl = document.getElementById("heroArt");
    const likeBtn = document.getElementById("heroLike");
    const items = Array.from(document.querySelectorAll("#heroLib .side__item, #heroLib2 .side__item"));

    const ART = {
      "cov--liked": "linear-gradient(135deg,#ff8a4c,#ff3b6b 60%,#3b0a14)",
      "cov--1": "linear-gradient(135deg,#3b82f6,#1e1b4b)",
      "cov--2": "linear-gradient(135deg,#f59e0b,#7c2d12)",
      "cov--3": "linear-gradient(135deg,#10b981,#064e3b)",
      "cov--4": "linear-gradient(135deg,#e5234b,#3b0a14)",
      "cov--5": "linear-gradient(135deg,#8b5cf6,#2e1065)",
      "cov--6": "linear-gradient(135deg,#06b6d4,#083344)",
    };

    const DURATION = 226; // 3:46
    let t = 108, playing = true, timer = null;

    const fmt = (s) => { s = Math.max(0, Math.floor(s)); return Math.floor(s / 60) + ":" + String(s % 60).padStart(2, "0"); };
    const render = () => { prog.style.width = (t / DURATION) * 100 + "%"; elapsed.textContent = fmt(t); };
    const tick = () => { t = t + 1 > DURATION ? 0 : t + 1; render(); };
    const start = () => { if (!timer && !reduceMotion) timer = setInterval(tick, 1000); };
    const stop = () => { clearInterval(timer); timer = null; };
    const setPlaying = (on) => {
      playing = on;
      win.classList.toggle("is-playing", on);
      playBtn.setAttribute("aria-label", on ? "Pause" : "Play");
      on ? start() : stop();
    };

    const selectItem = (li) => {
      items.forEach((x) => x.classList.remove("is-active"));
      li.classList.add("is-active");
      trackEl.textContent = li.dataset.track || trackEl.textContent;
      artistEl.textContent = li.dataset.artist || artistEl.textContent;
      artEl.style.background = ART[li.dataset.cov] || ART["cov--liked"];
      t = 0; render();
      if (!reduceMotion && artEl.animate) {
        artEl.animate([{ opacity: 0.3, transform: "scale(.9)" }, { opacity: 1, transform: "none" }], { duration: 340, easing: "cubic-bezier(.2,.8,.2,1)" });
        trackEl.animate([{ opacity: 0, transform: "translateY(5px)" }, { opacity: 1, transform: "none" }], { duration: 320, easing: "ease" });
      }
      setPlaying(true);
    };

    items.forEach((li) => li.addEventListener("click", () => selectItem(li)));
    playBtn.addEventListener("click", () => setPlaying(!playing));

    const step = (dir) => {
      const i = items.findIndex((x) => x.classList.contains("is-active"));
      selectItem(items[(i + dir + items.length) % items.length]);
    };
    document.getElementById("heroNext").addEventListener("click", () => step(1));
    document.getElementById("heroPrev").addEventListener("click", () => step(-1));

    likeBtn.addEventListener("click", () => {
      const liked = likeBtn.classList.toggle("is-liked");
      likeBtn.setAttribute("aria-pressed", String(liked));
      likeBtn.textContent = liked ? "♥" : "♡";
    });

    seek.addEventListener("click", (e) => {
      const r = seek.getBoundingClientRect();
      t = Math.max(0, Math.min(1, (e.clientX - r.left) / r.width)) * DURATION;
      render();
    });

    artEl.style.background = ART["cov--liked"];
    render();
    setPlaying(true);

    if ("IntersectionObserver" in window) {
      new IntersectionObserver((es) => es.forEach((en) => {
        if (!en.isIntersecting) stop(); else if (playing) start();
      }), { threshold: 0 }).observe(win);
    }
  })();

  /* ---------- feature card cursor spotlight ---------- */
  document.querySelectorAll(".card").forEach((card) => {
    card.addEventListener("pointermove", (e) => {
      const r = card.getBoundingClientRect();
      card.style.setProperty("--mx", ((e.clientX - r.left) / r.width) * 100 + "%");
      card.style.setProperty("--my", ((e.clientY - r.top) / r.height) * 100 + "%");
    });
  });

  /* ---------- scroll progress + active nav link ---------- */
  const sp = document.getElementById("scrollProgress");
  const navLinks = Array.from(document.querySelectorAll('.nav__links a[href^="#"]'));
  const updateProgress = () => {
    const h = document.documentElement;
    const max = h.scrollHeight - h.clientHeight;
    if (sp) sp.style.width = (max > 0 ? (h.scrollTop / max) * 100 : 0) + "%";
  };
  updateProgress();
  window.addEventListener("scroll", updateProgress, { passive: true });

  if ("IntersectionObserver" in window && navLinks.length) {
    const sections = navLinks.map((a) => document.querySelector(a.getAttribute("href"))).filter(Boolean);
    const so = new IntersectionObserver(
      (entries) => entries.forEach((en) => {
        if (en.isIntersecting) {
          const id = "#" + en.target.id;
          navLinks.forEach((a) => a.classList.toggle("is-active", a.getAttribute("href") === id));
        }
      }),
      { rootMargin: "-45% 0px -50% 0px", threshold: 0 }
    );
    sections.forEach((s) => so.observe(s));
  }

  /* ---------- showcase command-palette typewriter ---------- */
  (function typer() {
    const el = document.getElementById("showcaseType");
    if (!el) return;
    if (reduceMotion) { el.textContent = "floating points"; return; }
    const word = "floating points";
    let i = 0, dir = 1, hold = 0;
    const run = () => {
      if (hold > 0) { hold--; setTimeout(run, 90); return; }
      i += dir;
      el.textContent = word.slice(0, i);
      if (i >= word.length) { dir = -1; hold = 24; }
      else if (i <= 0) { dir = 1; hold = 12; }
      setTimeout(run, dir > 0 ? 95 : 45);
    };
    if ("IntersectionObserver" in window) {
      const io = new IntersectionObserver((es) => { if (es[0].isIntersecting) { io.disconnect(); run(); } }, { threshold: 0.3 });
      io.observe(el.closest(".showcase") || el);
    } else run();
  })();

  /* =========================================================
     Interactive 10-band equalizer
     ========================================================= */
  const FREQS = ["32", "64", "125", "250", "500", "1k", "2k", "4k", "8k", "16k"];
  const RANGE = 12; // +/- dB
  const PRESETS = {
    flat:   [0, 0, 0, 0, 0, 0, 0, 0, 0, 0],
    bass:   [9, 7.5, 6, 3, 0.5, 0, 0, 0, 1, 2],
    vocal:  [-3, -2, 0, 2.5, 5, 6, 4.5, 2, 0, -1],
    treble: [-1, 0, 0, 0, 1, 2.5, 4.5, 7, 9, 10],
    loud:   [8, 6, 3, 0, -2.5, -3, -1.5, 1.5, 6, 8],
  };

  const bandsEl = document.getElementById("eqBands");
  if (!bandsEl) return;

  const lineEl = document.getElementById("eqLine");
  const fillEl = document.getElementById("eqFill");
  const presetsEl = document.getElementById("eqPresets");
  const powerEl = document.getElementById("eqPower");
  const eqRoot = bandsEl.closest(".eq");

  let gains = PRESETS.flat.slice();
  const trackEls = [];
  const fillBars = [];
  const handleEls = [];
  const dbEls = [];

  // build bands
  FREQS.forEach((hz, i) => {
    const band = document.createElement("div");
    band.className = "band";
    band.innerHTML =
      '<div class="band__track" role="slider" tabindex="0" aria-label="' +
      hz +
      ' Hz" aria-valuemin="-12" aria-valuemax="12" aria-valuenow="0">' +
      '<div class="band__fill"></div><div class="band__handle"></div></div>' +
      '<span class="band__db">0</span><span class="band__hz">' +
      hz +
      "</span>";
    bandsEl.appendChild(band);

    const track = band.querySelector(".band__track");
    trackEls.push(track);
    fillBars.push(band.querySelector(".band__fill"));
    handleEls.push(band.querySelector(".band__handle"));
    dbEls.push(band.querySelector(".band__db"));

    const setFromY = (clientY) => {
      const r = track.getBoundingClientRect();
      let pct = 1 - (clientY - r.top) / r.height; // 0 bottom -> 1 top
      pct = Math.max(0, Math.min(1, pct));
      setGain(i, (pct * 2 - 1) * RANGE, true);
      clearActivePreset();
    };

    track.addEventListener("pointerdown", (e) => {
      track.setPointerCapture(e.pointerId);
      setFromY(e.clientY);
      const move = (ev) => setFromY(ev.clientY);
      const up = (ev) => {
        track.releasePointerCapture(e.pointerId);
        track.removeEventListener("pointermove", move);
        track.removeEventListener("pointerup", up);
      };
      track.addEventListener("pointermove", move);
      track.addEventListener("pointerup", up);
    });

    track.addEventListener("keydown", (e) => {
      let step = 0;
      if (e.key === "ArrowUp" || e.key === "ArrowRight") step = 1;
      else if (e.key === "ArrowDown" || e.key === "ArrowLeft") step = -1;
      else return;
      e.preventDefault();
      setGain(i, gains[i] + step, true);
      clearActivePreset();
    });

    track.addEventListener("dblclick", () => {
      setGain(i, 0, false);
      clearActivePreset();
    });
  });

  function setGain(i, val, smooth) {
    val = Math.max(-RANGE, Math.min(RANGE, Math.round(val * 2) / 2));
    gains[i] = val;
    const pct = (val + RANGE) / (RANGE * 2); // 0..1 from bottom
    const fill = fillBars[i];
    const handle = handleEls[i];
    // fill from center line up/down
    const center = 50;
    const offset = (val / RANGE) * 50;
    fill.style.transition = smooth ? "none" : "bottom .45s cubic-bezier(.2,.8,.2,1), height .45s cubic-bezier(.2,.8,.2,1)";
    handle.style.transition = smooth ? "none" : "bottom .45s cubic-bezier(.2,.8,.2,1)";
    if (val >= 0) {
      fill.style.bottom = center + "%";
      fill.style.height = offset + "%";
    } else {
      fill.style.bottom = center + offset + "%";
      fill.style.height = -offset + "%";
    }
    handle.style.bottom = pct * 100 + "%";
    dbEls[i].textContent = (val > 0 ? "+" : "") + (val % 1 === 0 ? val : val.toFixed(1));
    const track = trackEls[i];
    track.setAttribute("aria-valuenow", String(val));
    drawCurve();
  }

  // smooth response curve through 10 points (Catmull-Rom -> bezier)
  function drawCurve() {
    const W = 1000, H = 260, mid = H / 2;
    const n = gains.length;
    const pts = gains.map((g, i) => [
      (i / (n - 1)) * W,
      mid - (g / RANGE) * (mid - 16),
    ]);
    // pad ends so the curve reaches the edges flat-ish
    const ext = [pts[0]].concat(pts).concat([pts[n - 1]]);
    let d = "M " + pts[0][0] + " " + pts[0][1];
    for (let i = 1; i < ext.length - 2; i++) {
      const p0 = ext[i - 1], p1 = ext[i], p2 = ext[i + 1], p3 = ext[i + 2];
      const c1x = p1[0] + (p2[0] - p0[0]) / 6;
      const c1y = p1[1] + (p2[1] - p0[1]) / 6;
      const c2x = p2[0] - (p3[0] - p1[0]) / 6;
      const c2y = p2[1] - (p3[1] - p1[1]) / 6;
      d += " C " + c1x + " " + c1y + " " + c2x + " " + c2y + " " + p2[0] + " " + p2[1];
    }
    lineEl.setAttribute("d", d);
    fillEl.setAttribute("d", d + " L " + W + " " + H + " L 0 " + H + " Z");
  }

  function applyPreset(name, smooth) {
    const vals = PRESETS[name];
    if (!vals) return;
    vals.forEach((v, i) => setGain(i, v, !smooth ? false : false));
    // animate via transitions: re-run with smooth=false means transition runs
    vals.forEach((v, i) => {
      const pct = (v + RANGE) / (RANGE * 2);
      fillBars[i].style.transition = "bottom .5s cubic-bezier(.2,.8,.2,1), height .5s cubic-bezier(.2,.8,.2,1)";
      handleEls[i].style.transition = "bottom .5s cubic-bezier(.2,.8,.2,1)";
    });
  }

  function clearActivePreset() {
    presetsEl.querySelectorAll("button").forEach((b) => b.classList.remove("is-active"));
  }

  presetsEl.addEventListener("click", (e) => {
    const btn = e.target.closest("button");
    if (!btn) return;
    clearActivePreset();
    btn.classList.add("is-active");
    applyPreset(btn.dataset.preset, true);
  });

  // power toggle
  function setPower(on) {
    powerEl.setAttribute("aria-checked", String(on));
    eqRoot.classList.toggle("is-off", !on);
  }
  powerEl.addEventListener("click", () =>
    setPower(powerEl.getAttribute("aria-checked") !== "true")
  );
  powerEl.addEventListener("keydown", (e) => {
    if (e.key === " " || e.key === "Enter") {
      e.preventDefault();
      setPower(powerEl.getAttribute("aria-checked") !== "true");
    }
  });

  // init flat, then ease into a "loudness" curve once it scrolls in (delight)
  PRESETS.flat.forEach((v, i) => setGain(i, v, true));
  drawCurve();

  if (!reduceMotion && "IntersectionObserver" in window) {
    const teaser = new IntersectionObserver(
      (entries) => {
        entries.forEach((e) => {
          if (e.isIntersecting) {
            presetsEl.querySelectorAll("button").forEach((b) => b.classList.remove("is-active"));
            const target = presetsEl.querySelector('[data-preset="loud"]');
            if (target) target.classList.add("is-active");
            applyPreset("loud", true);
            teaser.unobserve(e.target);
          }
        });
      },
      { threshold: 0.45 }
    );
    teaser.observe(eqRoot);
  }
})();
