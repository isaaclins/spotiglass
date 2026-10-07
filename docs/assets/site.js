/* =========================================================
   Spotiglass — landing page interactions
   ========================================================= */
(function () {
  "use strict";

  const reduceMotion = window.matchMedia("(prefers-reduced-motion: reduce)").matches;

  /* ---------- always-fresh download link ----------
     Pull the newest .dmg from the GitHub Releases API so the CTA never goes
     stale. If anything fails we keep the hardcoded link in the HTML. */
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
})();
