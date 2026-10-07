#!/usr/bin/env python3
"""Local stand-in for accounts.spotify.com and api.spotify.com, used by screenshot mode.

Serves a sample library (sample-library.json) so Spotiglass can be run and captured without a
Spotify account. Track metadata and album artwork come from the public iTunes Search API at run
time and are cached in --cache; nothing is committed. Artwork URLs point straight at Apple's CDN.

    python3 scripts/screenshot-mode/mock_spotify.py --port 43900

Then launch the app with SPOTIGLASS_MOCK_BASE=http://127.0.0.1:43900 (scripts/screenshots.sh does
all of this). See docs/screenshots.md.
"""
import argparse
import hashlib
import json
import sys
import time
import urllib.parse
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

HERE = Path(__file__).resolve().parent
SCOPES = (
    "user-read-private user-read-email playlist-read-private playlist-read-collaborative "
    "playlist-modify-private playlist-modify-public user-library-read user-library-modify "
    "user-read-playback-state user-modify-playback-state user-read-currently-playing "
    "user-read-recently-played user-top-read user-follow-read user-follow-modify streaming"
)


# ---------- sample library ----------

def simple(text):
    return "".join(c for c in text.lower() if c.isalnum())


def best_match(results, artist, title):
    """The first result by this artist whose title starts with the one asked for, skipping remixes."""
    for r in results:
        if (simple(artist.split()[0]) in simple(r["artistName"])
                and simple(r["trackName"]).startswith(simple(title))
                and "remix" not in r["trackName"].lower()):
            return r
    return None


def itunes_search(query, attempts=4):
    for attempt in range(attempts):
        try:
            with urllib.request.urlopen("https://itunes.apple.com/search?" + query, timeout=20) as response:
                return json.load(response).get("results", [])
        except OSError:
            if attempt == attempts - 1:
                raise
            time.sleep(2 ** attempt)


def resolve_tracks(pairs, cache_path):
    """Look each (artist, title) up on the iTunes Search API once; later runs read the cache."""
    cache = json.loads(cache_path.read_text()) if cache_path.exists() else {}
    for artist, title in pairs:
        key = f"{artist} - {title}"
        if key in cache:
            continue
        query = urllib.parse.urlencode({"term": f"{artist} {title}", "entity": "song", "limit": 25})
        hit = best_match(itunes_search(query), artist, title)
        if hit is None:
            print(f"mock: no iTunes match for {key}, skipped", file=sys.stderr)
            continue
        cache[key] = {
            "requested": title,
            "artist": hit["artistName"],
            "title": hit["trackName"],
            "album": hit["collectionName"].removesuffix(" - Single").removesuffix(" - EP"),
            "ms": hit.get("trackTimeMillis", 200000),
            "year": hit.get("releaseDate", "2020")[:4],
            "artwork": hit["artworkUrl100"].replace("100x100bb", "640x640bb"),
        }
        time.sleep(0.3)  # stay polite to the public API
    cache_path.parent.mkdir(parents=True, exist_ok=True)
    cache_path.write_text(json.dumps(cache, indent=1))
    return [cache[f"{a} - {t}"] for a, t in pairs if f"{a} - {t}" in cache]


def sid(prefix, text):
    return prefix + hashlib.md5(text.encode()).hexdigest()[:20]


class Library:
    def __init__(self, spec, resolved, base):
        self.base = base
        self.user = spec.get("user", "Sample")
        self.tracks = [self._track(t) for t in resolved]
        self.by_title = {t["requested"]: track for t, track in zip(resolved, self.tracks)}
        self.playlists = [self._playlist(p) for p in spec["playlists"]]
        now = spec.get("nowPlaying", "")
        self.now_playing = self.by_title.get(now, self.tracks[0])
        self.started = time.time() - 111  # a little under two minutes into the song

    def images(self, url):
        return [{"url": url, "width": 640, "height": 640}]

    def artist(self, name, artwork=None):
        aid = sid("ar", name)
        out = {"id": aid, "name": name, "type": "artist", "uri": f"spotify:artist:{aid}",
               "href": f"{self.base}/v1/artists/{aid}", "external_urls": {"spotify": "https://open.spotify.com"}}
        if artwork:
            out.update(images=self.images(artwork), genres=["electronic"], followers={"total": 2400000}, popularity=72)
        return out

    def _track(self, t):
        tid = sid("tr", t["artist"] + t["title"])
        alid = sid("al", t["album"])
        album = {"id": alid, "name": t["album"], "type": "album", "album_type": "album", "uri": f"spotify:album:{alid}",
                 "images": self.images(t["artwork"]), "release_date": t["year"], "release_date_precision": "year",
                 "total_tracks": 10, "artists": [self.artist(t["artist"])], "href": f"{self.base}/v1/albums/{alid}",
                 "external_urls": {"spotify": "https://open.spotify.com"}}
        return {"id": tid, "name": t["title"], "type": "track", "uri": f"spotify:track:{tid}", "duration_ms": t["ms"],
                "explicit": False, "is_playable": True, "is_local": False, "popularity": 70, "track_number": 1,
                "disc_number": 1, "preview_url": None, "href": f"{self.base}/v1/tracks/{tid}",
                "external_urls": {"spotify": "https://open.spotify.com"}, "external_ids": {},
                "artists": [self.artist(t["artist"])], "album": album}

    def _playlist(self, p):
        pid = sid("pl", p["name"])
        tracks = [self.by_title[title] for title in p["tracks"] if title in self.by_title]
        return {"id": pid, "name": p["name"], "description": p.get("description", ""), "type": "playlist",
                "uri": f"spotify:playlist:{pid}", "public": False, "collaborative": False, "snapshot_id": "s1",
                "owner": {"id": "sample", "display_name": self.user, "type": "user", "uri": "spotify:user:sample"},
                "images": tracks[0]["album"]["images"] if tracks else [],
                "tracks": {"total": len(tracks), "href": f"{self.base}/v1/playlists/{pid}/tracks"},
                "items": {"total": len(tracks), "href": f"{self.base}/v1/playlists/{pid}/items"},
                "href": f"{self.base}/v1/playlists/{pid}", "external_urls": {"spotify": "https://open.spotify.com"},
                "_tracks": tracks}

    def artists(self):
        seen = {}
        for t in self.tracks:
            name = t["artists"][0]["name"]
            seen.setdefault(name, self.artist(name, t["album"]["images"][0]["url"]))
        return list(seen.values())

    def albums(self):
        return list({t["album"]["id"]: t["album"] for t in self.tracks}.values())

    def player(self):
        now = self.now_playing
        progress = int((time.time() - self.started) * 1000) % now["duration_ms"]
        return {"device": DEVICE, "shuffle_state": False, "smart_shuffle": False, "repeat_state": "off",
                "timestamp": int(time.time() * 1000), "progress_ms": progress, "is_playing": True, "item": now,
                "context": {"type": "playlist", "uri": self.playlists[0]["uri"], "href": self.playlists[0]["href"],
                            "external_urls": {}},
                "currently_playing_type": "track", "actions": {"disallows": {}}}

    def queue(self):
        i = self.tracks.index(self.now_playing)
        return (self.tracks[i + 1:] + self.tracks[:i])[:14]


DEVICE = {"id": "spotiglass-screenshot", "name": "Spotiglass", "type": "Computer", "is_active": True,
          "is_private_session": False, "is_restricted": False, "volume_percent": 72, "supports_volume": True}


def public(playlist):
    return {k: v for k, v in playlist.items() if not k.startswith("_")}


def page(items, query, base):
    limit = int(query.get("limit", ["50"])[0])
    offset = int(query.get("offset", ["0"])[0])
    return {"items": items[offset:offset + limit], "total": len(items), "limit": limit, "offset": offset,
            "next": None, "previous": None, "href": base}


# ---------- stand-in Web Playback SDK ----------
# Implements the parts of window.Spotify.Player that SpotifyPlaybackHost.html uses, playing a
# silent clock instead of audio so the player bar, scrubber and lyrics move as they would.

FAKE_SDK = r"""(function () {
  const S = __STATE__;
  class Player {
    constructor(options) { this.options = options; this.listeners = {}; this.paused = false;
      this.position = S.position; this.startedAt = Date.now(); this.volume = options.volume || 0.8; }
    addListener(event, cb) { (this.listeners[event] = this.listeners[event] || []).push(cb); return true; }
    on(event, cb) { return this.addListener(event, cb); }
    removeListener(event) { delete this.listeners[event]; return true; }
    emit(event, arg) { (this.listeners[event] || []).forEach((cb) => { try { cb(arg); } catch (_) {} }); }
    state() {
      const position = this.paused ? this.position : this.position + (Date.now() - this.startedAt);
      return { paused: this.paused, position: position % S.duration, duration: S.duration, loading: false,
        shuffle: false, repeat_mode: 0, timestamp: Date.now(), context: { uri: S.context, metadata: {} },
        disallows: {}, track_window: { current_track: S.current, previous_tracks: [], next_tracks: S.next } };
    }
    connect() {
      try { this.options.getOAuthToken(() => {}); } catch (_) {}
      setTimeout(() => {
        this.emit('ready', { device_id: S.device });
        setTimeout(() => this.emit('player_state_changed', this.state()), 300);
        setInterval(() => this.emit('player_state_changed', this.state()), 4000);
      }, 200);
      return Promise.resolve(true);
    }
    disconnect() {}
    getCurrentState() { return Promise.resolve(this.state()); }
    togglePlay() { return this.paused ? this.resume() : this.pause(); }
    pause() { if (!this.paused) { this.position += Date.now() - this.startedAt; this.paused = true; }
      this.emit('player_state_changed', this.state()); return Promise.resolve(); }
    resume() { if (this.paused) { this.startedAt = Date.now(); this.paused = false; }
      this.emit('player_state_changed', this.state()); return Promise.resolve(); }
    seek(ms) { this.position = ms; this.startedAt = Date.now(); this.emit('player_state_changed', this.state());
      return Promise.resolve(); }
    nextTrack() { return Promise.resolve(); }
    previousTrack() { return Promise.resolve(); }
    setVolume(v) { this.volume = v; return Promise.resolve(); }
    getVolume() { return Promise.resolve(this.volume); }
    activateElement() { return Promise.resolve(); }
    setName() { return Promise.resolve(); }
  }
  window.Spotify = { Player };
  (function waitForHost() {
    if (typeof window.onSpotifyWebPlaybackSDKReady === 'function') window.onSpotifyWebPlaybackSDKReady();
    else setTimeout(waitForHost, 30);
  })();
})();"""


def sdk_track(t):
    return {"id": t["id"], "uri": t["uri"], "name": t["name"], "duration_ms": t["duration_ms"], "type": "track",
            "media_type": "audio", "artists": [{"name": a["name"], "uri": a["uri"]} for a in t["artists"]],
            "album": {"name": t["album"]["name"], "uri": t["album"]["uri"], "images": t["album"]["images"]}}


# ---------- HTTP ----------

def make_handler(lib):
    base = lib.base

    class Handler(BaseHTTPRequestHandler):
        def log_message(self, fmt, *args):
            sys.stderr.write(f"{self.command} {self.path}\n")

        def send(self, code, body=None, content_type="application/json", headers=None):
            data = b"" if body is None else body if isinstance(body, bytes) else json.dumps(body).encode()
            self.send_response(code)
            for key, value in (headers or {}).items():
                self.send_header(key, value)
            if data:
                self.send_header("Content-Type", content_type)
            self.send_header("Content-Length", str(len(data)))
            self.end_headers()
            self.wfile.write(data)

        def discard_body(self):
            self.rfile.read(int(self.headers.get("Content-Length") or 0))

        def do_GET(self):
            url = urllib.parse.urlparse(self.path)
            q = urllib.parse.parse_qs(url.query)
            path = url.path.rstrip("/")
            parts = path.split("/")
            tracks = lib.tracks

            if path == "/health":
                return self.send(200, {"ok": True})
            if path == "/authorize":  # only reached when someone signs out and reconnects
                location = q["redirect_uri"][0] + "?" + urllib.parse.urlencode(
                    {"code": "screenshot-mode", "state": q.get("state", [""])[0]})
                return self.send(302, headers={"Location": location})
            if path == "/sdk/spotify-player.js":
                state = {"current": sdk_track(lib.now_playing), "next": [sdk_track(t) for t in lib.queue()[:3]],
                         "duration": lib.now_playing["duration_ms"], "position": 111000,
                         "context": lib.playlists[0]["uri"], "device": DEVICE["id"]}
                return self.send(200, FAKE_SDK.replace("__STATE__", json.dumps(state)).encode(),
                                 "application/javascript")

            if path == "/v1/me":
                return self.send(200, {"id": "sample", "display_name": lib.user, "country": "CH",
                                       "product": "premium", "images": [], "uri": "spotify:user:sample",
                                       "type": "user"})
            if path == "/v1/me/playlists":
                return self.send(200, page([public(p) for p in lib.playlists], q, base))
            if path == "/v1/me/tracks":
                saved = [{"added_at": f"2026-09-{1 + i % 28:02d}T10:00:00Z", "track": t} for i, t in enumerate(tracks)]
                return self.send(200, page(saved, q, base))
            if path == "/v1/me/tracks/contains":
                return self.send(200, [True for _ in q.get("ids", [""])[0].split(",")])
            if path == "/v1/me/library/contains":
                return self.send(200, [True for _ in q.get("uris", [""])[0].split(",")])
            if path.startswith("/v1/playlists/"):
                playlist = next((p for p in lib.playlists if p["id"] == parts[3]), lib.playlists[0])
                items = [{"added_at": "2026-09-12T10:00:00Z", "is_local": False, "track": t, "item": t}
                         for t in playlist["_tracks"]]
                if len(parts) > 4:
                    return self.send(200, page(items, q, base))
                return self.send(200, dict(public(playlist), tracks=page(items, q, base)))
            if path in ("/v1/me/player", "/v1/me/player/currently-playing"):
                return self.send(200, lib.player())
            if path == "/v1/me/player/devices":
                return self.send(200, {"devices": [DEVICE]})
            if path == "/v1/me/player/queue":
                return self.send(200, {"currently_playing": lib.now_playing, "queue": lib.queue()})
            if path == "/v1/me/player/recently-played":
                played = [{"track": t, "played_at": f"2026-10-07T08:{i:02d}:00Z", "context": None}
                          for i, t in enumerate(tracks[:20])]
                return self.send(200, {"items": played, "next": None, "cursors": {}, "limit": 20, "href": base})
            if path.startswith("/v1/me/top/artists"):
                return self.send(200, page(lib.artists(), q, base))
            if path.startswith("/v1/me/top/tracks"):
                return self.send(200, page(tracks, q, base))
            if path == "/v1/me/albums":
                saved = [{"added_at": "2026-09-01T10:00:00Z", "album": dict(a, tracks=page([], {}, base))}
                         for a in lib.albums()[:12]]
                return self.send(200, page(saved, q, base))
            if path == "/v1/me/following":
                artists = lib.artists()[:12]
                return self.send(200, {"artists": {"items": artists, "next": None, "total": len(artists),
                                                   "limit": 50, "cursors": {}, "href": base}})
            if path.startswith("/v1/artists/"):
                artist = next((a for a in lib.artists() if a["id"] == parts[3]), lib.artists()[0])
                own = [t for t in tracks if t["artists"][0]["id"] == artist["id"]]
                if path.endswith("/top-tracks"):
                    return self.send(200, {"tracks": own})
                if path.endswith("/albums"):
                    return self.send(200, page([t["album"] for t in own], q, base))
                return self.send(200, artist)
            if path.startswith("/v1/albums/"):
                own = [t for t in tracks if t["album"]["id"] == parts[3]] or tracks[:1]
                if path.endswith("/tracks"):
                    return self.send(200, page(own, q, base))
                return self.send(200, dict(own[0]["album"], tracks=page(own, q, base)))
            if path.startswith("/v1/tracks/"):
                return self.send(200, next((t for t in tracks if t["id"] == parts[3]), lib.now_playing))
            if path == "/v1/search":
                term = q.get("q", [""])[0].lower()

                def hit(*fields):
                    return any(term in f.lower() for f in fields)

                return self.send(200, {
                    "tracks": page([t for t in tracks if hit(t["name"], t["artists"][0]["name"], t["album"]["name"])], q, base),
                    "artists": page([a for a in lib.artists() if hit(a["name"])], q, base),
                    "albums": page([a for a in lib.albums() if hit(a["name"], a["artists"][0]["name"])], q, base),
                    "playlists": page([public(p) for p in lib.playlists if hit(p["name"])], q, base),
                })

            sys.stderr.write(f"mock: unhandled GET {self.path}\n")
            return self.send(404, {"error": {"status": 404, "message": "not in the screenshot mock"}})

        def do_POST(self):
            self.discard_body()
            if self.path.startswith("/api/token"):
                return self.send(200, {"access_token": "screenshot-mode", "token_type": "Bearer", "scope": SCOPES,
                                       "expires_in": 3600, "refresh_token": "screenshot-mode"})
            return self.send(204)

        def do_PUT(self):
            self.discard_body()
            return self.send(204)

        do_DELETE = do_PUT

    return Handler


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--port", type=int, default=43900)
    parser.add_argument("--library", type=Path, default=HERE / "sample-library.json")
    parser.add_argument("--cache", type=Path, default=Path("build/screenshot-mode/library-cache.json"))
    parser.add_argument("--now-playing", help="title of the track shown as playing (default: from the library)")
    args = parser.parse_args()

    spec = json.loads(args.library.read_text())
    if args.now_playing:
        spec["nowPlaying"] = args.now_playing
    base = f"http://127.0.0.1:{args.port}"
    lib = Library(spec, resolve_tracks(spec["tracks"], args.cache), base)
    print(f"mock: {len(lib.tracks)} tracks, {len(lib.playlists)} playlists, playing "
          f"{lib.now_playing['name']} on {base}", file=sys.stderr)
    ThreadingHTTPServer(("127.0.0.1", args.port), make_handler(lib)).serve_forever()


if __name__ == "__main__":
    main()
