# Suwayomi Single Chapter Download Design

## Goal

Add the first real download flow to the KOReader Suwayomi plugin: selecting a chapter should download that single chapter into the configured KOReader download directory as a `.cbz` file.

The initial scope is intentionally narrow:

- one chapter at a time
- foreground download flow
- success/failure surfaced through KOReader messages
- target layout: `Download Directory / Manga Title / Chapter Name.cbz`
- if the target file already exists, skip it instead of overwriting

This design is based on live testing against the user's Suwayomi instance, including Local source chapters backed by existing `.cbz` files.

## What The Live Server Confirmed

### Page retrieval model

`fetchChapterPages(input: { chapterId })` returns a list of per-page API URLs plus chapter metadata. It does **not** return a single chapter archive URL.

Example shape:

```graphql
mutation Pages($input: FetchChapterPagesInput!) {
  fetchChapterPages(input: $input) {
    pages
    chapter {
      id
      name
      isDownloaded
      pageCount
      manga { title }
    }
  }
}
```

The returned `pages` entries are API paths such as:

```text
/api/v1/manga/85/chapter/1/page/0
```

Those URLs return image bytes directly when requested with the same Basic Auth credentials as GraphQL.

### Local source corner case

For Local source, the GraphQL chapter id and the chapter id embedded in the returned page URLs are not the same.

Observed example:

- GraphQL chapter id: `398`
- returned page URLs under: `/api/v1/manga/85/chapter/1/page/...`

Because of this, the plugin must treat the returned `pages` list as authoritative and must **not** try to reconstruct page URLs from chapter ids.

### Archive download shortcut is not viable

The chapter `url` field currently reflects a server-side relative path such as:

```text
Sousou no Frieren/Official_Vol. 1 Ch. 1.cbz
```

That is not a directly usable client download URL.

Passing `format: "cbz"` to `fetchChapterPages` only appends `?format=cbz` to the page URLs; it does not expose a single archive download endpoint we can rely on for chapter export.

## Recommended Approach

Download all pages for the selected chapter, then build a local `.cbz` file in KOReader using KOReader's built-in archive writer.

Why this approach:

- it works with the live Local source behavior we already verified
- it should also work later for remote sources that expose chapter pages through the same API
- it produces the flat filesystem layout the user wants
- it does not depend on Suwayomi's own server-side downloader state or storage conventions

Alternatives considered:

1. Server-side download queue via `enqueueChapterDownload`
   This may be useful later for bulk downloads, but it does not solve "get chapter file onto the KOReader device" cleanly for the first slice.

2. Save pages as a plain folder of images
   Simpler, but worse than `.cbz` for library cleanliness and not what the user currently wants.

## User-Facing Behavior

### Chapter selection

Selecting a chapter from the existing chapter menu starts a single chapter download immediately.

### Success path

On success, the plugin creates:

```text
<download_directory>/<manga_title>/<chapter_name>.cbz
```

and shows a confirmation message including the saved path.

### Existing file

If the target file already exists, the plugin skips the download and shows a message that the chapter already exists locally.

### Missing configuration

If no download directory has been configured, the plugin stops early and shows a message instructing the user to set one first.

### Failure behavior

Failures should be friendly and specific where possible:

- missing download directory
- missing or invalid Suwayomi credentials
- unable to fetch chapter pages
- unable to download one or more page images
- unable to create the manga folder
- unable to write the `.cbz`

No partial success should be reported as success.

## File and Module Design

### `main.lua`

Replace the chapter tap placeholder with a real call into the downloader.

Responsibilities:

- load saved credentials
- load configured download directory
- hand the selected chapter to the downloader
- surface returned success or error messages to the user

`main.lua` should remain orchestration-only and not own download internals.

### `suwayomi_api.lua`

Extend the API layer with chapter page fetching and binary page download support.

Additions:

- `fetchChapterPages(credentials, chapter_id)`
  - GraphQL mutation wrapper around `fetchChapterPages`
  - returns parsed chapter metadata plus the exact page URL list from Suwayomi

- `downloadBinary(credentials, relative_or_absolute_url)`
  - authenticated HTTP GET for binary content
  - supports both relative API paths and absolute URLs

- parsing helpers for chapter page payloads

Important rule:

- page URLs returned by Suwayomi must be used exactly as returned

### `suwayomi_downloader.lua`

This file will become the real single-chapter downloader instead of a queue stub.

Responsibilities:

- validate target directory
- compute target manga directory and target `.cbz` path
- skip existing files
- fetch chapter pages through `SuwayomiAPI`
- download page image bytes sequentially
- write a `.cbz` using `ffi/archiver`

Expected public entry point:

- `downloadChapter(credentials, download_directory, manga, chapter)`

Expected return shape:

```lua
{
  ok = true,
  path = ".../Sousou no Frieren/Official_Vol. 1 Ch. 1.cbz",
}
```

or

```lua
{
  ok = false,
  error = "Could not download chapter pages.",
}
```

Internal helper responsibilities:

- path and filename building
- minimal filesystem-safe sanitization
- directory creation
- page filename generation inside the archive
- archive lifecycle handling

### `suwayomi_settings.lua`

No new settings are required for the first slice.

The existing download directory setting remains the only file-target setting.

### `suwayomi_ui.lua`

No structural UI changes are required for the first slice.

The chapter menu remains the same; only its callback behavior changes.

## Filesystem Layout

The user wants a flat, understandable structure, not the Kahon layout.

Chosen layout:

```text
Download Directory/
  Manga Title/
    Chapter Name.cbz
```

We will use Suwayomi titles directly and only sanitize the minimum set of characters that are invalid or dangerous for filesystem paths.

Sanitization goals:

- preserve visible names as much as possible
- replace path separators and invalid filename characters
- avoid empty filenames after sanitization

This is intentionally lighter than Mihon's more opinionated naming scheme.

## Archive Construction

Use KOReader's built-in `ffi/archiver` writer to create ZIP archives with a `.cbz` extension.

Archive entry naming:

- each page becomes a zero-padded filename inside the archive
- preferred pattern: `0001.<ext>`, `0002.<ext>`, ...

Extension choice:

- derive from the HTTP `Content-Type` when possible
- fall back to a safe default if the content type is missing or unknown

Compression:

- use default ZIP behavior unless there is a clear reason to set a specific mode

The downloader must close the archive cleanly on both success and failure. If writing fails midway, the partially written target file should be removed if possible.

## Networking and Data Flow

### Download sequence

1. `main.lua` receives manga and chapter selection
2. `suwayomi_downloader.downloadChapter(...)` validates inputs
3. `suwayomi_api.fetchChapterPages(...)` returns:
   - chapter metadata
   - exact page URL list
4. downloader creates target manga folder if needed
5. downloader opens target `.cbz`
6. downloader downloads each page URL in order
7. downloader writes each page into the archive with deterministic filenames
8. downloader closes the archive
9. downloader returns success with target path

### Networking assumptions

- Basic Auth is reused for page downloads
- page URLs may be relative API paths and must be joined against `server_url`
- binary downloads must not route through the JSON GraphQL helpers

## Error Handling

The downloader should fail fast with clear messages.

Cases to handle explicitly:

- empty download directory
- no chapter pages returned
- one page download fails
- non-image response returned for a page
- archive open failure
- archive write failure
- directory creation failure

Behavior on failure:

- stop the current chapter download
- close archive if it was opened
- remove partial output file when possible
- return a single user-facing error message

## Testing Strategy

Every real bug or live-server quirk we discover should gain coverage.

### Unit tests to add

#### `spec/suwayomi_api_spec.lua`

- chapter pages payload parsing
- relative page URLs are preserved exactly
- Local source mismatch case is covered by using returned page URLs instead of derived ids
- binary download helper handles relative URLs correctly

#### `spec/suwayomi_downloader_spec.lua`

- target path generation
- existing file causes skip
- empty download directory fails
- successful archive creation from mocked page bytes
- page download failure aborts and reports error
- partial file cleanup on failure

#### `spec/main_spec.lua`

- chapter selection invokes downloader
- success path shows saved-path message
- skip/error paths show the returned message

### Live verification

Manual verification should use the user's real Suwayomi instance and specifically cover:

- Local source chapter download
- chapter re-download skip behavior
- resulting `.cbz` opens in KOReader from the configured directory

## Scope Boundaries

This design intentionally does **not** include:

- bulk chapter downloads
- background queueing
- progress UI
- cancellation
- metadata sidecars
- ComicInfo.xml generation
- server-side Suwayomi download queue integration

Those can be layered on later after the single-chapter path is proven stable.

## Success Criteria

This feature is successful when:

1. selecting a chapter downloads it as a `.cbz`
2. the file lands under `Download Directory / Manga Title / Chapter Name.cbz`
3. existing files are skipped without overwrite
4. Local source works using the returned page URLs
5. unit tests cover the live quirks discovered during development
6. the resulting `.cbz` is readable by KOReader
