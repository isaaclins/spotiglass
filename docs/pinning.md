## Sidebar pins

Spotiglass can pin playlists, Liked Songs, artists, albums, and individual tracks to the **Home** section of the sidebar. Pins are per Spotify user (see [Data storage](data-storage.md) for the on-disk path).

## Gestures

- **Drag-to-pin.** Drag any pinnable row onto the **Home** pinned list to add a new pin. Sources are: sidebar playlist rows, the Liked Songs sidebar row, the playlist-detail header, the artist-detail header, the album cards on an artist page, and the track rows inside playlists and artist top-tracks. The drag preview is a compact pill with a kind icon (playlist, artist, album, track, or Liked Songs) and the title.
- **Drag-to-reorder.** Drag a pinned row up or down inside the pinned list to change its position. A dashed insertion bar previews the drop slot.
- **Drag-to-unpin.** Drop a pinned row anywhere outside the pinned list (the rest of the sidebar or the detail pane) to remove it.
- **Hover ✕.** Hovering a pinned row reveals an ✕ badge in the top-left of its artwork; clicking it unpins.
- **Right-click.** Every pinnable surface offers **Pin to Sidebar** / **Unpin from Sidebar** in its context menu (the pinned rows themselves use the shorter **Unpin**).

Already-pinned source rows show a small `pin.fill` glyph on their artwork so you can tell at a glance what is already in the sidebar.

## Command palette

- With a search result highlighted, **⌘↩** runs **Pin** when that row exposes a pin action (tracks, playlists, artists, albums, and “This playlist” matches). Rows that are already pinned expose **Unpin** for the separate `palette.unpin` command (no default shortcut).
- Pinning from the palette does **not** close the palette.

## Sign out

**Disconnect** clears the Spotify cache directory, including pinned JSON for that machine. The in-memory pin list is cleared as soon as you disconnect so the UI does not show another account’s pins before the next bind.
