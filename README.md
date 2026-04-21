# Suwayomi Downloader for KOReader

A KOReader plugin that allows you to browse and asynchronously download manga from your self-hosted [Suwayomi (Tachidesk)](https://github.com/Suwayomi/Suwayomi-Server) server directly to your e-ink device.

## Features
- Native KOReader UI integration
- Browse sources, manga, and chapters directly from the server
- Asynchronous background downloading of chapters (no frozen UI!)
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
5. Tap **Browse Suwayomi** to explore your server and download chapters.

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
