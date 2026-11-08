/* Spotiglass landing page.
   Keeps the download buttons and the version line on the newest release. If the GitHub API
   can't be reached, the links in the HTML (the release this page was written for) stay. */
(function () {
  "use strict";

  fetch("https://api.github.com/repos/isaaclins/spotiglass/releases/latest", {
    headers: { Accept: "application/vnd.github+json" },
  })
    .then(function (response) {
      return response.ok ? response.json() : Promise.reject(response.status);
    })
    .then(function (release) {
      var dmg = (release.assets || []).find(function (asset) {
        return /\.dmg$/i.test(asset.name);
      });
      if (dmg) {
        document.querySelectorAll("a.js-download").forEach(function (link) {
          link.href = dmg.browser_download_url;
        });
      }
      var version = (release.tag_name || "").replace(/^v/, "");
      if (version) {
        document.querySelectorAll(".js-version").forEach(function (el) {
          el.textContent = "Version " + version;
        });
      }
    })
    .catch(function () {});
})();
