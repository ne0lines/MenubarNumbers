# MenubarNumbers

MenubarNumbers is a native macOS menu-bar dashboard for live values from one or more REST/JSON APIs. Connect an endpoint, keep its request values in Keychain, test the response, then show scalar values in the macOS menu bar or on Stream Deck keys.

![MenubarNumbers source editor screenshot](docs/screenshots/source-editor.png)

## What it does

- Stores multiple GET/POST REST/JSON sources locally.
- Keeps authentication, headers, query values, and request bodies in macOS Keychain; persisted configuration contains only UUID references.
- Supports bearer, Basic, API-key header, and API-key query authentication.
- Inspects JSON responses through RFC 6901 JSON Pointers.
- Lets you drag scalar values into a simulated menu bar and reorder them.
- Formats numbers and dates, sets labels/templates/fallbacks, and uses the same renderer for the preview and `MenuBarExtra`.
- Polls only enabled sources that are used by the current layout, with coalesced refreshes and no overlapping requests.
- Makes every scalar API value available to a macOS Stream Deck plugin.
- Renders either a value alone or, for numbers, the value over a persisted 60-sample sparkline.

![MenubarNumbers menu bar builder screenshot](docs/screenshots/menu-bar-builder.png)

![MenubarNumbers menu bar output screenshot](docs/screenshots/menu-bar-output.png)

## Requirements

- macOS 14 or newer
- Xcode with Swift 6 support
- An HTTPS API, or HTTP on localhost/loopback for local development
- Stream Deck 7.1 or newer for the optional plugin
- Node.js 24 or newer when developing the plugin

## Run locally

```bash
xcodebuild -project MenubarNumbers.xcodeproj \
  -scheme MenubarNumbers \
  -destination 'platform=macOS' \
  CODE_SIGNING_ALLOWED=NO \
  build
```

Open `MenubarNumbers.xcodeproj` in Xcode to run the app normally. The app stays active after its settings window is closed and exposes the combined live value through the macOS menu bar.

Run the complete test suite with:

```bash
xcodebuild test \
  -project MenubarNumbers.xcodeproj \
  -scheme MenubarNumbers \
  -destination 'platform=macOS' \
  CODE_SIGNING_ALLOWED=NO
```

Build and test the Stream Deck plugin with:

```bash
cd streamdeck
npm ci
npm test
npm run pack
```

The packaged installer is written to `streamdeck/dist/com.davidhermansson.menubarnumbers.streamDeckPlugin`.

## Stream Deck plugin

1. Install and launch MenubarNumbers, then configure and test at least one API source.
2. Download the `.streamDeckPlugin` artifact from a release and double-click it to install.
3. In the Stream Deck application, drag **MenubarNumbers → API Data** onto a key.
4. Select an API source and search for any scalar value in its latest JSON response.
5. Choose **Value** or, for numeric fields, **Value + sparkline**.

MenubarNumbers must remain running for live updates. If it stops or an API request fails, the plugin retains the last successful value, dims the key, and shows a warning indicator. Key settings and cached values survive Stream Deck restarts; numeric histories survive MenubarNumbers restarts.

## Configuration flow

1. Add an API source and enter its base URL, method, interval, auth, headers, query parameters, and optional JSON body.
2. Save and test the source. The response is shown as a navigable JSON tree.
3. Drag a scalar node, or use its **Add to Menu Bar** action, in the Menu Bar workspace.
4. Set its label, template, fallback, numeric precision, or date style.
5. The simulated preview and the real menu-bar item update from the same layout and formatter.

## Security model

Configuration is stored locally as JSON metadata. Secret and request values are written to Keychain and referenced by UUID; they are resolved only while constructing a request. Errors and status messages are sanitized so response bodies and credentials are not shown. A 2 MiB response limit, HTTPS policy, and cancellation-aware refresh gate protect the live polling path.

The Stream Deck plugin never receives endpoint URLs, request headers, query parameters, request bodies, or credentials. MenubarNumbers exposes only source names, JSON Pointers, scalar values, timestamps, sanitized status, and numeric history through a bearer-authenticated server bound to `127.0.0.1`. Its dynamic port and random token are stored in a user-only discovery file under Application Support.

## Release flow

`dev` is the integration branch. Changes are merged from `dev` into `main`; every push to `main` runs [`.github/workflows/release.yml`](.github/workflows/release.yml), tests both components, builds the unsigned macOS app and Stream Deck plugin, and creates a GitHub release with generated notes.

```bash
git switch dev
git push origin dev

# after review/merge to main
git push origin main
```

Each release publishes both a drag-to-Applications DMG and an installable `.streamDeckPlugin`, with SHA-256 files for each. The macOS app is intentionally unsigned. Add Apple Developer signing/notarization credentials to the workflow before distributing it outside a development environment.

## Architecture

- `MenubarNumbersCore`: Codable configuration, Keychain access, JSON Pointer traversal, API client, formatting, polling, sanitized Stream Deck bridge contracts, subscription leases, sparkline history, routing, and loopback HTTP transport.
- `MenubarNumbers`: SwiftUI settings/source editor, JSON inspector, drag-and-drop menu-bar builder, persistence, and `MenuBarExtra`.
- `streamdeck`: TypeScript Stream Deck plugin, Property Inspector, SVG renderer, offline cache, tests, validation, and packaging.
- `MenubarNumbersCoreTests`: unit and loopback integration tests covering request construction, auth, error safety, JSON selection, formatting, persistence boundaries, polling, Stream Deck data, and cancellation races.

## License

No license has been selected yet.
