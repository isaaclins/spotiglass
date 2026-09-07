/* =========================================================
   Spotiglass — landing page interactions
   ========================================================= */
(function () {
  "use strict";

  const reduceMotion = window.matchMedia("(prefers-reduced-motion: reduce)").matches;

  /* Keep the fallback link useful when the Releases API is unavailable. */
  (function freshenDownload() {
    fetch("https://api.github.com/repos/isaaclins/spotiglass/releases/latest", {
      headers: { Accept: "application/vnd.github+json" },
    })
      .then((response) => (response.ok ? response.json() : Promise.reject(response.status)))
      .then((release) => {
        const dmg = (release.assets || []).find((asset) => /\.dmg$/i.test(asset.name));
        if (dmg) {
          document.querySelectorAll("a.js-download").forEach((link) => {
            link.href = dmg.browser_download_url;
          });
        }
      })
      .catch(() => {
        /* Keep the versioned fallback href from the HTML. */
      });
  })();

  /* ---------- sticky navigation ---------- */
  const header = document.querySelector(".site-header");
  const updateHeader = () => header?.classList.toggle("is-stuck", window.scrollY > 12);
  updateHeader();
  window.addEventListener("scroll", updateHeader, { passive: true });

  /* ---------- scroll reveal ---------- */
  const revealElements = document.querySelectorAll("[data-reveal]");
  if (reduceMotion || !("IntersectionObserver" in window)) {
    revealElements.forEach((element) => element.classList.add("is-in"));
  } else {
    const revealObserver = new IntersectionObserver(
      (entries) => {
        entries.forEach((entry) => {
          if (entry.isIntersecting) {
            entry.target.classList.add("is-in");
            revealObserver.unobserve(entry.target);
          }
        });
      },
      { threshold: 0.12, rootMargin: "0px 0px -2% 0px" }
    );
    revealElements.forEach((element) => revealObserver.observe(element));
  }

  /* ---------- hero mini-player ---------- */
  (function heroPlayer() {
    const windowEl = document.getElementById("heroWindow");
    if (!windowEl) return;

    const playButton = document.getElementById("heroPlay");
    const seek = document.getElementById("heroSeek");
    const elapsed = document.getElementById("heroElapsed");
    const trackElement = document.getElementById("heroTrack");
    const artistElement = document.getElementById("heroArtist");
    const artElement = document.getElementById("heroArt");
    const likeButton = document.getElementById("heroLike");
    const nextButton = document.getElementById("heroNext");
    const previousButton = document.getElementById("heroPrev");
    const items = Array.from(document.querySelectorAll("#heroLib .side__item, #heroLib2 .side__item"));

    const art = {
      "cov--liked": "linear-gradient(135deg,#a53b45,#65313a)",
      "cov--1": "linear-gradient(135deg,#567289,#293b4b)",
      "cov--2": "linear-gradient(135deg,#a87543,#65452f)",
      "cov--3": "linear-gradient(135deg,#558371,#345848)",
      "cov--4": "linear-gradient(135deg,#9d4b55,#542c34)",
      "cov--5": "linear-gradient(135deg,#756d8c,#454056)",
      "cov--6": "linear-gradient(135deg,#4c8490,#2e535f)",
    };

    const duration = 226;
    let time = 108;
    let playing = true;
    let timer = null;

    const formatTime = (seconds) => {
      const wholeSeconds = Math.max(0, Math.floor(seconds));
      return `${Math.floor(wholeSeconds / 60)}:${String(wholeSeconds % 60).padStart(2, "0")}`;
    };

    const render = () => {
      const progress = (time / duration) * 100;
      seek.value = String(Math.round(time));
      seek.style.setProperty("--progress", progress.toFixed(2));
      seek.setAttribute("aria-valuetext", `${formatTime(time)} of ${formatTime(duration)}`);
      elapsed.textContent = formatTime(time);
    };

    const tick = () => {
      time = time + 1 > duration ? 0 : time + 1;
      render();
    };

    const start = () => {
      if (!timer && !reduceMotion) timer = window.setInterval(tick, 1000);
    };

    const stop = () => {
      window.clearInterval(timer);
      timer = null;
    };

    const setPlaying = (isPlaying) => {
      playing = isPlaying;
      windowEl.classList.toggle("is-playing", isPlaying);
      playButton.setAttribute("aria-label", isPlaying ? "Pause" : "Play");
      playButton.setAttribute("aria-pressed", String(isPlaying));
      if (isPlaying) start();
      else stop();
    };

    const selectItem = (item) => {
      items.forEach((entry) => entry.classList.remove("is-active"));
      item.classList.add("is-active");
      trackElement.textContent = item.dataset.track || trackElement.textContent;
      artistElement.textContent = item.dataset.artist || artistElement.textContent;
      artElement.style.background = art[item.dataset.cov] || art["cov--liked"];
      time = 0;
      render();
      setPlaying(true);
    };

    items.forEach((item) => item.addEventListener("click", () => selectItem(item)));
    playButton.addEventListener("click", () => setPlaying(!playing));
    nextButton.addEventListener("click", () => {
      const current = items.findIndex((item) => item.classList.contains("is-active"));
      selectItem(items[(current + 1) % items.length]);
    });
    previousButton.addEventListener("click", () => {
      const current = items.findIndex((item) => item.classList.contains("is-active"));
      selectItem(items[(current - 1 + items.length) % items.length]);
    });

    likeButton.addEventListener("click", () => {
      const liked = likeButton.classList.toggle("is-liked");
      likeButton.setAttribute("aria-pressed", String(liked));
      likeButton.setAttribute("aria-label", liked ? "Unlike song" : "Like song");
      likeButton.textContent = liked ? "♥" : "♡";
    });

    seek.addEventListener("input", () => {
      time = Number(seek.value);
      render();
    });

    artElement.style.background = art["cov--liked"];
    render();
    setPlaying(true);

    if ("IntersectionObserver" in window) {
      new IntersectionObserver(
        (entries) => entries.forEach((entry) => {
          if (!entry.isIntersecting) stop();
          else if (playing) start();
        }),
        { threshold: 0 }
      ).observe(windowEl);
    }
  })();

  /* ---------- scroll progress and active navigation link ---------- */
  const progressBar = document.getElementById("scrollProgress");
  const navLinks = Array.from(document.querySelectorAll('.site-nav__links a[href^="#"]'));

  const updateProgress = () => {
    const documentElement = document.documentElement;
    const maximum = documentElement.scrollHeight - documentElement.clientHeight;
    if (progressBar) {
      progressBar.style.width = `${maximum > 0 ? (documentElement.scrollTop / maximum) * 100 : 0}%`;
    }
  };

  updateProgress();
  window.addEventListener("scroll", updateProgress, { passive: true });

  if ("IntersectionObserver" in window && navLinks.length) {
    const sections = navLinks
      .map((link) => document.querySelector(link.getAttribute("href")))
      .filter(Boolean);
    const sectionObserver = new IntersectionObserver(
      (entries) => entries.forEach((entry) => {
        if (entry.isIntersecting) {
          const id = `#${entry.target.id}`;
          navLinks.forEach((link) => {
            const active = link.getAttribute("href") === id;
            link.classList.toggle("is-active", active);
            if (active) link.setAttribute("aria-current", "location");
            else link.removeAttribute("aria-current");
          });
        }
      }),
      { rootMargin: "-45% 0px -50% 0px", threshold: 0 }
    );
    sections.forEach((section) => sectionObserver.observe(section));
  }

  /* ---------- command palette typewriter ---------- */
  (function typePaletteQuery() {
    const element = document.getElementById("showcaseType");
    if (!element) return;
    const word = "floating points";
    if (reduceMotion) {
      element.textContent = word;
      return;
    }

    let index = 0;
    let direction = 1;
    let hold = 0;
    const run = () => {
      if (hold > 0) {
        hold -= 1;
        window.setTimeout(run, 90);
        return;
      }
      index += direction;
      element.textContent = word.slice(0, index);
      if (index >= word.length) {
        direction = -1;
        hold = 22;
      } else if (index <= 0) {
        direction = 1;
        hold = 12;
      }
      window.setTimeout(run, direction > 0 ? 95 : 48);
    };

    if ("IntersectionObserver" in window) {
      const typeObserver = new IntersectionObserver((entries) => {
        if (entries[0].isIntersecting) {
          typeObserver.disconnect();
          run();
        }
      }, { threshold: 0.3 });
      typeObserver.observe(element.closest(".showcase") || element);
    } else {
      run();
    }
  })();

  /* ---------- interactive 10-band equalizer ---------- */
  (function equalizer() {
    const bandsElement = document.getElementById("eqBands");
    if (!bandsElement) return;

    const lineElement = document.getElementById("eqLine");
    const fillElement = document.getElementById("eqFill");
    const presetsElement = document.getElementById("eqPresets");
    const powerElement = document.getElementById("eqPower");
    const equalizerElement = bandsElement.closest(".equalizer");
    const frequencies = ["32", "64", "125", "250", "500", "1k", "2k", "4k", "8k", "16k"];
    const range = 12;
    const presets = {
      flat: [0, 0, 0, 0, 0, 0, 0, 0, 0, 0],
      bass: [9, 7.5, 6, 3, 0.5, 0, 0, 0, 1, 2],
      vocal: [-3, -2, 0, 2.5, 5, 6, 4.5, 2, 0, -1],
      treble: [-1, 0, 0, 0, 1, 2.5, 4.5, 7, 9, 10],
      loud: [8, 6, 3, 0, -2.5, -3, -1.5, 1.5, 6, 8],
    };

    const gains = presets.flat.slice();
    const tracks = [];
    const fills = [];
    const handles = [];
    const values = [];

    frequencies.forEach((frequency, index) => {
      const band = document.createElement("div");
      band.className = "band";
      band.innerHTML = `<div class="band__track" role="slider" tabindex="0" aria-label="${frequency} Hz band" aria-valuemin="-12" aria-valuemax="12" aria-valuenow="0"><div class="band__fill"></div><div class="band__handle"></div></div><span class="band__db">0</span><span class="band__hz">${frequency}</span>`;
      bandsElement.appendChild(band);

      const track = band.querySelector(".band__track");
      tracks.push(track);
      fills.push(band.querySelector(".band__fill"));
      handles.push(band.querySelector(".band__handle"));
      values.push(band.querySelector(".band__db"));

      const setFromY = (clientY) => {
        const bounds = track.getBoundingClientRect();
        const percentage = Math.max(0, Math.min(1, 1 - (clientY - bounds.top) / bounds.height));
        setGain(index, (percentage * 2 - 1) * range, false);
        clearActivePreset();
      };

      track.addEventListener("pointerdown", (event) => {
        track.setPointerCapture(event.pointerId);
        setFromY(event.clientY);
        const move = (moveEvent) => setFromY(moveEvent.clientY);
        const up = () => {
          track.removeEventListener("pointermove", move);
          track.removeEventListener("pointerup", up);
        };
        track.addEventListener("pointermove", move);
        track.addEventListener("pointerup", up);
      });

      track.addEventListener("keydown", (event) => {
        let step = 0;
        if (event.key === "ArrowUp" || event.key === "ArrowRight") step = 1;
        if (event.key === "ArrowDown" || event.key === "ArrowLeft") step = -1;
        if (!step) return;
        event.preventDefault();
        setGain(index, gains[index] + step, false);
        clearActivePreset();
      });

      track.addEventListener("dblclick", () => {
        setGain(index, 0, true);
        clearActivePreset();
      });
    });

    function setGain(index, value, animate) {
      const gain = Math.max(-range, Math.min(range, Math.round(value * 2) / 2));
      gains[index] = gain;
      const percentage = ((gain + range) / (range * 2)) * 100;
      const offset = (gain / range) * 50;
      fills[index].style.transition = animate ? "bottom .4s ease, height .4s ease" : "none";
      handles[index].style.transition = animate ? "bottom .4s ease" : "none";
      if (gain >= 0) {
        fills[index].style.bottom = "50%";
        fills[index].style.height = `${offset}%`;
      } else {
        fills[index].style.bottom = `${50 + offset}%`;
        fills[index].style.height = `${-offset}%`;
      }
      handles[index].style.bottom = `${percentage}%`;
      values[index].textContent = `${gain > 0 ? "+" : ""}${gain % 1 === 0 ? gain : gain.toFixed(1)}`;
      tracks[index].setAttribute("aria-valuenow", String(gain));
      tracks[index].setAttribute("aria-valuetext", `${gain > 0 ? "+" : ""}${gain} dB`);
      drawCurve();
    }

    function drawCurve() {
      const width = 1000;
      const height = 260;
      const middle = height / 2;
      const points = gains.map((gain, index) => [
        (index / (gains.length - 1)) * width,
        middle - (gain / range) * (middle - 16),
      ]);
      const extended = [points[0], ...points, points[points.length - 1]];
      let path = `M ${points[0][0]} ${points[0][1]}`;
      for (let index = 1; index < extended.length - 2; index += 1) {
        const p0 = extended[index - 1];
        const p1 = extended[index];
        const p2 = extended[index + 1];
        const p3 = extended[index + 2];
        const c1x = p1[0] + (p2[0] - p0[0]) / 6;
        const c1y = p1[1] + (p2[1] - p0[1]) / 6;
        const c2x = p2[0] - (p3[0] - p1[0]) / 6;
        const c2y = p2[1] - (p3[1] - p1[1]) / 6;
        path += ` C ${c1x} ${c1y} ${c2x} ${c2y} ${p2[0]} ${p2[1]}`;
      }
      lineElement.setAttribute("d", path);
      fillElement.setAttribute("d", `${path} L ${width} ${height} L 0 ${height} Z`);
    }

    function clearActivePreset() {
      presetsElement.querySelectorAll("button").forEach((button) => button.classList.remove("is-active"));
    }

    function applyPreset(name) {
      presets[name].forEach((gain, index) => setGain(index, gain, true));
    }

    presetsElement.addEventListener("click", (event) => {
      const button = event.target.closest("button");
      if (!button) return;
      clearActivePreset();
      button.classList.add("is-active");
      applyPreset(button.dataset.preset);
    });

    powerElement.addEventListener("click", () => {
      const enabled = powerElement.getAttribute("aria-checked") !== "true";
      powerElement.setAttribute("aria-checked", String(enabled));
      powerElement.setAttribute("aria-label", enabled ? "Disable equalizer" : "Enable equalizer");
      equalizerElement.classList.toggle("is-off", !enabled);
    });

    gains.forEach((gain, index) => setGain(index, gain, false));
    drawCurve();

    if (!reduceMotion && "IntersectionObserver" in window) {
      const teaserObserver = new IntersectionObserver((entries) => {
        if (!entries[0].isIntersecting) return;
        clearActivePreset();
        const loudness = presetsElement.querySelector('[data-preset="loud"]');
        loudness?.classList.add("is-active");
        applyPreset("loud");
        teaserObserver.disconnect();
      }, { threshold: 0.45 });
      teaserObserver.observe(equalizerElement);
    }
  })();
})();
