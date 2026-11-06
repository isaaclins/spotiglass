# Apple Music (developer preview)

Spotiglass is getting Apple Music support next to Spotify (#372). This first part is
**browsing only**: your Apple Music library, playlists, Home and search, read through Apple's
MusicKit. Playback comes next, and the service switcher (#373) after that. Until the switcher
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
- **Disconnect** is hidden in Apple Music mode (toolbar, palette, app menu): access is a system permission, turned off in System Settings → Privacy & Security → Media & Apple Music, and switching services belongs to #373. Settings › Account shows a note instead of the Spotify sign-in, and Apple Music mode never reads, refreshes or deletes the saved Spotify sign-in.
- Cover art of songs that only live in your cloud library may not load; those rows show the
  placeholder.
