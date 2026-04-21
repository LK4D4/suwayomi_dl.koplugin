# Suwayomi Browse Design

## Goal

Implement the next read-only browsing slice for the KOReader plugin:

1. list sources
2. select a source to list manga
3. select a manga to list chapters

Downloads are explicitly out of scope for this slice.

## Constraints

- Use the real Suwayomi instance during development to validate the live GraphQL schema and response shapes.
- Preserve server-returned ordering for manga and chapters.
- Keep the KOReader UI simple and menu-based for now.
- Every bug found through the live instance should result in a unit test when practical.

## Current State

- Login persistence works through `LuaSettings`.
- Source browsing works against the live server.
- Source filtering by selected languages is implemented.
- Basic auth and HTTPS handling were already debugged against the real server.

## Proposed Implementation

### API Layer

Extend `suwayomi_api.lua` with:

- a query for manga under a source
- a query for chapters under a manga
- parsers for each response shape
- fetch helpers that mirror the existing `fetchSources` pattern

The GraphQL queries should be discovered and verified against the live Suwayomi server, not guessed from stale examples.

### UI Layer

Extend `suwayomi_ui.lua` with:

- `showMangaMenu(manga_list, onSelect)`
- `showChapterMenu(chapter_list, onSelect)`

Both should follow the same simple menu pattern used by the sources menu.

### Plugin Flow

Update `main.lua` so that:

- selecting a source fetches and displays manga for that source
- selecting a manga fetches and displays chapters for that manga
- selecting a chapter shows a placeholder message such as `Download not implemented yet`

### Error Handling

Handle these cases with user-visible messages:

- source returns no manga
- manga returns no chapters
- GraphQL schema mismatch
- malformed response body
- auth/network/server failures

### Testing Strategy

Add unit tests for:

- new query builders
- manga response parsing
- chapter response parsing
- source -> manga -> chapter callback flow

When live-instance debugging uncovers a real bug, add or expand a unit test that reproduces the failure shape before or alongside the fix.

## Out of Scope

- chapter downloads
- bulk download queueing
- chapter progress tracking
- pagination/search optimization
- polished UI beyond simple menus

## Risks

- Suwayomi GraphQL shapes may differ from assumptions and require live validation.
- Manga and chapter titles may contain missing or inconsistent fields.
- Large source catalogs may eventually require pagination or search, but that is deferred.

## Success Criteria

- Browse from source list to manga list to chapter list on the real Suwayomi instance.
- Preserve server ordering.
- Show meaningful errors instead of crashing or silently failing.
- Add regression tests for real bugs found during live-server development.
