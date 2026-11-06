# Apple Music (developer preview)

Spotiglass is getting Apple Music support next to Spotify (#372). This part is **browsing**:
your Apple Music library, playlists, Home and search, read through Apple's MusicKit. Playback
comes next.

## Turning it on

Pick Apple Music on the welcome screen of a fresh install, or click the service name at the top
left of the sidebar and choose **Add a service…**. The system asks for access to Apple Music;
there is no client ID and nothing else to set up.

## Switching between Spotify and Apple Music

Each added service is its own space, like a browser profile: its own sign-in, pins and the place
you left it. Switching never signs you out.

- Click the service at the top left of the sidebar: every added service is listed, the one on
  screen has a checkmark.
- ⌃1 switches to Apple Music, ⌃2 to Spotify (rebindable in Settings › Keyboard), or use
  **Switch to Spotify** / **Switch to Apple Music** in the command palette (`>switch`).
- What is playing keeps playing until you start something from the other library.
- Settings › Account signs each service in and out on its own. Signing out of Apple Music
  removes it from the menu (its pins stay for when you add it again); the access itself is a
  system permission in System Settings › Privacy & Security › Media & Apple Music. Signing out of
  Spotify while Apple Music is added hands the window to Apple Music; as the only service,
  Spotify shows its own sign-in again, as before.

The list of added services and the one on screen are kept in `UserDefaults`
([`MusicServiceStore`](../Spotiglass/Infrastructure/MusicServiceSelection.swift)). The first
launch of this version sets them up from what is already there: a saved Spotify client ID adds
Spotify, so an existing Spotify setup opens straight into Spotify with its pins and caches
untouched (both are keyed by the Spotify account, not by the service). The old developer switch
`SpotiglassMusicService=appleMusic` carries over as an added Apple Music.

Screenshot mode only offers Apple Music when started with `--with-apple-music`, and the unit-test
host never reaches MusicKit.

The grant belongs to the app's code signature, so a build signed with a different identity asks
again. If you said no, the app points you to System Settings → Privacy & Security → Media & Apple
Music.

### Requirements

- The MusicKit app service enabled for the bundle ID `com.isaaclins.spotiglass` in the Apple
  Developer portal. MusicKit then issues the developer token by itself: no provisioning profile,
  no MusicKit entitlement and no notarization are needed, and an ad hoc or Developer ID signed
  build both work. Don't add `com.apple.developer.musickit` to the entitlements.
- `NSAppleMusicUsageDescription` in Info.plist (set in the build settings, translated in
  `Spotiglass/InfoPlist.xcstrings`).
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

## Not there yet

- **Playback.** The transport bar says playing is coming soon, and play buttons do nothing.
  Apple's player will publish Now Playing itself once it lands.
- **Library edits** (rename, add to playlist, like): MusicKit's library is read-only on macOS.
  The menus report them as unsupported. #374 covers them.
- **Track counts** for library playlists: MusicKit only knows them after loading the tracks, so
  the sidebar says "Track count unavailable".
- **Artist pages** opened from the library show the albums in your library and tracks from them,
  not the artist's whole catalog.
- **Disconnect** is hidden for Apple Music (toolbar, palette, app menu): signing out of it lives in Settings › Account. An Apple Music-only setup never reads, refreshes or deletes a saved Spotify sign-in.
- Cover art of songs that only live in your cloud library may not load; those rows show the
  placeholder.
