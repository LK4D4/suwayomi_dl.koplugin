# Suwayomi Downloader for KOReader

A KOReader plugin that allows you to browse your self-hosted [Suwayomi (Tachidesk)](https://github.com/Suwayomi/Suwayomi-Server) server and download chapters directly to your e-ink device.

## Development Status

This plugin is experimental and still under active development.

- Expect rough edges and incomplete features.
- The login flow, source browsing, manga browsing, chapter browsing, and single-chapter downloads are currently implemented and being tested.
- Bulk downloads and background queueing are not complete yet.

## Features
- Native KOReader UI integration
- Browse sources, manga, and chapters directly from the server
- Single-chapter downloading of chapters
- Select custom download directories (perfect for treating downloaded chapters as local books)

## Installation

1. Download the latest `suwayomi_dl.koplugin.zip` from the [Releases page](../../releases).
2. Extract the zip file.
3. Copy the `suwayomi_dl.koplugin` directory to the KOReader plugins directory on your device:
   - For Android/e-readers: Usually `koreader/plugins/`
   - So the final path should be `koreader/plugins/suwayomi_dl.koplugin/main.lua`
4. Restart KOReader.

## Usage

1. Open the **Search** tab in KOReader's top menu.
2. Tap **Suwayomi**.
3. First time use: Tap **Setup login information** to enter your Suwayomi Server URL, username, and password.
4. Tap **Setup download directory** to choose where manga will be downloaded.
5. Tap **Browse Suwayomi** to explore the server.
6. Tap a chapter to download it into the configured directory as a `.cbz`.

## Testing Locally

This plugin uses Busted for unit testing. To run tests locally:

```bash
# Install busted via luarocks
luarocks install busted

# Run tests
busted spec/
```

## Contributing

Pull requests are welcome! Please ensure any new features have accompanying unit tests in the `spec/` directory.
