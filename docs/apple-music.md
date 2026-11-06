# Apple Music (developer preview)

Spotiglass is getting Apple Music support next to Spotify (#372). So far it covers **browsing**
(your Apple Music library, playlists, Home and search, read through Apple's MusicKit) and
**library edits** (like, save albums, create, rename and delete playlists, add and remove songs;
see [Library edits](#library-edits)). Playback and the service switcher (#373) come next. Until the switcher
exists, Apple Music is reachable only through a hidden developer switch. A normal launch is
Spotify, exactly as before.

## Turning it on

Pass a launch argument:

```sh
make build
open build/DerivedData/Build/Products/Debug/Spotiglass.app --args -SpotiglassMusicService appleMusic
```

or set it for every launch, and remove it again to go back to Spotify:

```sh
defaults write com.isaaclins.spotiglass SpotiglassMusicService appleMusic
defaults delete com.isaaclins.spotiglass SpotiglassMusicService
```

Screenshot mode and the unit-test host ignore the switch and always run Spotify
([`MusicServiceSelection`](../Spotiglass/Infrastructure/MusicServiceSelection.swift)).

On first launch the app asks for Apple Music access. The grant belongs to the app's code
signature, so a build signed with a different identity asks again. If you said no, the app points
you to System Settings → Privacy & Security → Media & Apple Music.

### Requirements

- The MusicKit app service enabled for the bundle ID `com.isaaclins.spotiglass` in the Apple
  Developer portal. MusicKit then issues the developer token by itself: no provisioning profile,
  no MusicKit entitlement and no notarization are needed, and an ad hoc or Developer ID signed
  build both work. Don't add `com.apple.developer.musickit` to the entitlements.
- `NSAppleMusicUsageDescription` and `NSAppleEventsUsageDescription` in Info.plist (set in the
  build settings, translated in `Spotiglass/InfoPlist.xcstrings`), and the
  `com.apple.security.automation.apple-events` entitlement for edits through the Music app.
- An Apple Music subscription for catalog search, recommendations and (later) playback. The
  library itself loads without one.

## What maps where

[`AppleMusicBrowsingProvider`](../Spotiglass/Services/AppleMusicBrowsingProvider.swift)
implements `MusicBrowsingProvider`; the MusicKit requests themselves live in
[`MusicKitContentSource`](../Spotiglass/Services/AppleMusicContentSource.swift).

| Spotiglass | Apple Music |
|---|---|
| Library playlists | `MusicLibraryRequest<Playlist>` |
| Liked Songs | The songs in your library, newest first (`MusicLibraryRequest<Song>`). Apple Music has no separate "liked" list a Mac app can read; loving a song is a rating, and MusicKit on macOS has no request for loved songs. The library is what you chose to keep, which is what Liked Songs is on Spotify. |
| Home: Recently played | `MusicRecentlyPlayedRequest<Song>`, with one catalog request to attach each song's album (Home groups them by album) |
| Home: Your top tracks | The songs of your personal mix from `MusicPersonalRecommendationsRequest` (the Favourites mix is built from what you play most); otherwise the first recommended playlist |
| Playlist / album / artist detail | Library first, then the catalog (`MusicCatalogResourceRequest`) |
| Search and the ⌘K palette | Library matches first (`MusicLibrarySearchRequest`, up to 100 per type on the first page, since the library can't be paged), then the catalog (`MusicCatalogSearchRequest`, the requested page size, at most 25). Later pages are catalog only. Catalog copies of library items are hidden on every page, and each result type pages on its own. |
| Artwork | Catalog artwork is a plain https URL and goes through the normal image cache. Library artwork comes as `musicKit://` URLs that only MusicKit can draw, so the artwork views render it with MusicKit's `ArtworkImage` ([`AppleMusicArtworkRegistry`](../Spotiglass/Services/AppleMusicArtworkRegistry.swift)). |

Apple Music items keep their MusicKit IDs, and their `uri` is `applemusic:<kind>:<id>`. Pins and
the library row order are stored under their own user ID (`apple-music-library`), so they never
mix with a Spotify account's. The Apple Music browser keeps no disk cache: library reads are
local, and library artwork URLs only live as long as MusicKit's session. Spotify's cache, Keychain
item and session are never read or written in Apple Music mode.

## Library edits

MusicKit's own library is read-only on macOS, so edits take one of two routes
([`AppleMusicLibraryEditor`](../Spotiglass/Services/AppleMusicLibraryEditor.swift)):

| Edit | Route |
|---|---|
| Like a song (Add to Liked Songs) | Apple Music API: `POST /v1/me/library` saves it, `PUT /v1/me/ratings/songs/{id}` loves it, the way the Music app's Favorite does |
| Unlike a song | Music app: removes the song from the library; the API clears the love |
| Add album to library | Apple Music API: `POST /v1/me/library` |
| Remove album from library | Music app: removes the album's songs from the library |
| New playlist | Apple Music API: `POST /v1/me/library/playlists` |
| Add to playlist | Apple Music API: `POST /v1/me/library/playlists/{id}/tracks` |
| Remove from this playlist, move to playlist | Music app (move adds through the API first) |
| Rename and delete playlist | Music app |

The API requests go through `MusicDataRequest`, which signs them with the developer token and the
user token by itself. The Music app is driven through Apple Events
([`MusicAppLibraryScripting`](../Spotiglass/Services/MusicAppLibraryScripting.swift)), which costs
one system prompt, "Spotiglass wants to control Music" (`NSAppleEventsUsageDescription`, and
`com.apple.security.automation.apple-events` for the hardened runtime). Spotiglass starts Music
hidden when it isn't running. If you say no, browsing keeps working and the edit shows a one-line
hint pointing to System Settings › Privacy & Security › Automation. Every change reaches your other
devices through iCloud Music Library.

The menu items that Spotify mode doesn't have (Remove from this playlist, Delete playlist…, Add or
remove album) appear only for a provider that supports them (`MusicLibraryEdits`), so Spotify's
menus are unchanged.

**IDs.** The API names songs by catalog or cloud library ID (`i.…`) and playlists by `p.…`; the
Music app names both by its persistent ID, which MusicKit shows as a signed decimal (inside a
playlist even for songs that have an `i.` ID elsewhere). MusicKit writes the other IDs out when an
item is encoded, which is where Spotiglass reads them. Nothing maps a `p.` ID to a persistent ID,
so a library playlist is found among your cloud playlists by its name, and two editable playlists
with the same name stop the edit instead of guessing.

**Catching up.** An edit is in your cloud library at once, but the library MusicKit reads on this
Mac follows later: a new playlist showed up after 20 seconds in one test and not within half an
hour in another, and the Music app had a liked song about 20 seconds after the like. So the browser
lays its own edits over MusicKit's reads
([`AppleMusicPendingLibraryEdits`](../Spotiglass/Services/AppleMusicPendingLibraryEdits.swift),
memory only, at most 500 per kind and 12 hours) until the library shows them. Removing a song
seconds after liking it may say "Music on this Mac doesn't have this change yet"; trying again a
moment later works.

## Not there yet

- **Playback.** The transport bar says playing is coming soon, and play buttons do nothing.
  Apple's player will publish Now Playing itself once it lands.
- **Reordering a playlist.** Spotiglass has no drag-to-reorder for playlist tracks yet, on either
  service.
- **Track counts** for library playlists: MusicKit only knows them after loading the tracks, so
  the sidebar says "Track count unavailable".
- **Artist pages** opened from the library show the albums in your library and tracks from them,
  not the artist's whole catalog.
- **Disconnect** is hidden in Apple Music mode (toolbar, palette, app menu): access is a system permission, turned off in System Settings → Privacy & Security → Media & Apple Music, and switching services belongs to #373. Settings › Account shows a note instead of the Spotify sign-in, and Apple Music mode never reads, refreshes or deletes the saved Spotify sign-in.
- Cover art of songs that only live in your cloud library may not load; those rows show the
  placeholder.
