# Apple Music (developer preview)

Spotiglass is getting Apple Music support next to Spotify (#372). You can browse your Apple
Music library, playlists, Home and search, play them, and edit your library (like, save albums,
create, rename and delete playlists, add and remove songs; see [Library edits](#library-edits)),
through Apple's MusicKit, and switch between Apple Music and Spotify at any time.

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
- What is playing keeps playing until you start something from the other library: each service
  has its own player, and starting music in one pauses the other.
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
- `NSAppleMusicUsageDescription` and `NSAppleEventsUsageDescription` in Info.plist (set in the
  build settings, translated in `Spotiglass/InfoPlist.xcstrings`), and the
  `com.apple.security.automation.apple-events` entitlement for edits through the Music app.
- An Apple Music subscription for catalog search, recommendations and playback. The library
  itself loads without one; without a subscription the transport bar says playing needs one.

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
| Artwork | Catalog artwork is a plain https URL and goes through the normal image cache. Library artwork comes as `musicKit://` URLs that only MusicKit can draw, so the artwork views render it with MusicKit's `ArtworkImage` ([`AppleMusicArtworkRegistry`](../Spotiglass/Services/AppleMusicArtworkRegistry.swift), bounded to 20,000 artworks, least recently drawn first out, so covers on screen and on pins keep drawing). |

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
| New playlist | Apple Music API: `POST /v1/me/library/playlists`, with the songs in the same request; for songs only the Music app knows (below), the Music app, which deletes the new playlist again if a song can't be added. Either way a failed create leaves no empty playlist. |
| Add to playlist | Apple Music API: `POST /v1/me/library/playlists/{id}/tracks`; for songs only the Music app knows, the Music app, which takes its own adds out again if one fails partway |
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

**Removing from the library asks first.** Liked Songs are your library, so removing a song from
Liked Songs (or an album from the library) deletes it from the library, and Music then also takes
it out of every playlist it's in, on all your devices
([Apple](https://support.apple.com/en-us/HT204343)). Spotiglass asks before it does that, the way
Music asks before Delete from Library. Spotify's unlike only leaves Liked Songs and still goes
through at once (`MusicLibraryEdits.confirmLibraryRemoval`).

Songs of library playlists and library albums come from MusicKit with only the Music persistent
ID, no catalog or cloud library ID, so the API can't name them. Their playlist edits go through the
Music app, which finds the song in the library or, for an Apple Music song that is in a playlist
but not in the library, in the playlist it was listed in. One edit always takes one route.

**Liked or not, for a playlist row.** A playlist can hold Apple Music songs that aren't in your
library, and MusicKit lists them like library songs. Only a song in the library has the date it was
added (`libraryAddedDate`), which is what the track menu goes by: no date offers Add to Liked
Songs (checked against the Music app on 22 rows of two playlists, #401). Liking such a song saves
it through the API by its catalog ID, which MusicKit keeps only on the song's library entry
(found by title, matched by persistent ID). Removing an album from the library leaves out its songs
that are only in a playlist, since Music couldn't find them there. Liked Songs leaves them out too:
on one library MusicKit listed 2552 songs, and the 956 with a date were exactly the 956 the Apple
Music API counts as library songs.

Scripts to Music run off the main thread, one at a time, and each Apple Event gives up after 60
seconds (the Music app still loading or syncing), so the window never waits on Music. A lookup
that times out changed nothing and says "Music didn't respond". A change that times out is
different: AppleScript only stops waiting, and Music still carries the change out (#411). So the
edit then waits for Music to answer again (Music answers one event at a time, so its next answer
comes after the slow change), up to 10 minutes, and ends in a state it can report truthfully:

| Edit | After a change that answered late |
|---|---|
| Unlike, remove album, remove from playlist, rename, delete playlist | Finished: whatever is still to do is done, and the edit succeeds. |
| Add to playlist, New playlist… | Taken back: the songs it added (the late one too) come out again, or the new playlist is deleted, and the edit says "Music didn't respond". |

If Music still doesn't answer after that wait, the edit says the change may still go through.

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

## Playback

[`AppleMusicPlaybackProvider`](../Spotiglass/Playback/AppleMusicPlaybackProvider.swift)
implements `MusicPlaybackProvider` on MusicKit's `ApplicationMusicPlayer`
([`MusicKitApplicationPlayer`](../Spotiglass/Playback/MusicKitApplicationPlayer.swift)).

| Spotiglass | Apple Music |
|---|---|
| Play a row, Liked Songs, a playlist, an album, an artist | The songs are queued one by one as `ApplicationMusicPlayer.Queue` entries, starting at the row you picked. Rows are played as the exact MusicKit song they were built from ([`AppleMusicPlayableRegistry`](../Spotiglass/Services/AppleMusicPlayableRegistry.swift), bounded to 20,000 songs, least recently used first out): a library request for a playlist track's id answers with a song under a different id, so a second lookup can't be matched back to the row. |
| Pause, resume, seek, next, previous, shuffle, repeat | The player's own commands. Repeat off / context / track maps to none / all / one. |
| Add to queue | After the current song and after the songs added before it, like Spotify's queue. |
| Queue panel | The entries after the current one. |
| Player state | Read, not pushed: the session polls it (every second after a command, while the app is in the background too). |
| Volume | MusicKit has no volume for the app's player, so the volume control is hidden and the Mac's volume applies. |
| Now Playing, Control Center, media keys | Apple's player publishes Now Playing and answers the remote commands itself; Spotiglass writes nothing there. |
| Lyrics | LRCLIB, by title, artist, album and duration, cached under `applemusic-song-<id>`. |

MusicKit's player answers a command before its state shows it. Measured on a Mac mini M4
(macOS 27): after `pause()` it reported "playing" for up to 333 ms, after `play()` "paused" for
up to 297 ms, after `skipToNextEntry()` the old song (at position 0) for up to 305 ms, after
`skipToPreviousEntry()` for up to 189 ms, and after `stop()` it reports "paused" after about
70 ms. The session reads right after a command and then every second, so the settle window of
two reads hides the first, stale read and applies the second. A read during that window that
still shows the song a skip left is ignored. `AppleMusicPlaybackProviderTests` replays these
timings.

The equalizer routes the Mac's default output through its own device, and MusicKit plays to the
default output, so Apple Music goes through it as well.

## Not there yet

- **Music videos** can't be queued by MusicKit's player on macOS; they are skipped when a list
  is played.
- **Reordering a playlist.** Spotiglass has no drag-to-reorder for playlist tracks yet, on either
  service.
- **Track counts** for library playlists: MusicKit only knows them after loading the tracks, so
  the sidebar says "Track count unavailable".
- **Artist pages** opened from the library show the albums in your library and tracks from them,
  not the artist's whole catalog. A library album's track count is the number of its songs in
  your library, the same songs its album page lists.
- **Disconnect** is hidden for Apple Music (toolbar, palette, app menu): signing out of it lives in Settings › Account. An Apple Music-only setup never reads, refreshes or deletes a saved Spotify sign-in.
- Cover art of songs that only live in your cloud library may not load; those rows show the
  placeholder.
