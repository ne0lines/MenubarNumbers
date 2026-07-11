# Stream Deck Plugin Design

## Goal

Add a macOS-only Stream Deck plugin that reuses the API sources configured in MenubarNumbers. A Stream Deck key can select any scalar value from any configured API response and display either the value alone or, for numeric values, the current value over a sparkline.

MenubarNumbers remains the only component that owns endpoints, request values, authentication, Keychain access, API polling, and numeric history.

## Scope

The first version provides one reusable Stream Deck action named **API Data** for keypad keys. Each action instance selects one source and one RFC 6901 JSON Pointer.

Included:

- Selection of any scalar JSON value, whether or not it is used in the menu bar.
- Value-only rendering for strings, numbers, booleans, and null.
- Value plus sparkline rendering for numbers.
- Persisted numeric history.
- Cached stale/offline rendering when MenubarNumbers is unavailable.
- Local-only communication between the Stream Deck plugin and MenubarNumbers.

Excluded:

- Configuring API requests or credentials in Stream Deck.
- Multiple values on one key.
- Stream Deck encoders or touch strips.
- Windows support.
- Key presses that mutate remote APIs.
- User-configurable colors, fonts, history length, or chart algorithms.

## Architecture

### MenubarNumbersCore

Core owns platform-neutral bridge contracts and value processing:

- Flatten a `JSONValue` response into scalar descriptors containing source ID, JSON Pointer, label, type, current value, and update time.
- Represent bridge requests and responses without endpoint URLs, request headers, query parameters, request bodies, or credentials.
- Maintain numeric histories keyed by source ID and JSON Pointer.
- Keep the latest 60 successful numeric samples for each active sparkline subscription.
- Encode histories for durable local persistence and tolerate a missing or corrupt history file by starting with an empty history.

### MenubarNumbers app

The app starts an HTTP bridge bound only to `127.0.0.1` on a dynamically selected port. At launch it atomically writes a discovery file under the user's MenubarNumbers Application Support directory. The file contains the port and a random bearer token and is readable only by the current user. The file is replaced when the bridge restarts.

Every bridge request requires the bearer token. The server rejects non-loopback access and returns only sanitized bridge data. API configuration and Keychain-backed values are never serialized into bridge responses or plugin settings.

The bridge supports these logical operations; exact route names may be refined in the implementation plan without changing their contracts:

- List configured sources and their availability.
- Fetch or refresh the scalar catalogue for one source.
- Register the active Stream Deck selections and their display modes.
- Fetch current values, histories, timestamps, and sanitized status for active selections.

Polling uses the union of source IDs referenced by the menu-bar layout and active Stream Deck subscriptions. Opening the Property Inspector may request a one-time refresh of a source so that all scalar fields can be selected even when the source is not yet active elsewhere.

### Stream Deck plugin

A separate TypeScript project lives under `streamdeck/` and produces an installable `.streamDeckPlugin` artifact. It uses the official `@elgato/streamdeck` SDK and an HTML Property Inspector.

The plugin process:

- Reads the discovery file and authenticates to the loopback bridge.
- Tracks all visible API Data action instances.
- Sends the union of active selections to MenubarNumbers.
- Performs one batched snapshot request per local update cycle and fans results out to keys.
- Persists each action's source ID, JSON Pointer, and display mode using Stream Deck action settings.
- Caches the last successfully received rendered state locally for offline display.
- Renders scalable SVG images and applies them with the Stream Deck key image API.

No API endpoint, request value, or credential is stored in Stream Deck settings.

## Property Inspector

The Property Inspector presents:

1. An API source selector.
2. A searchable list of scalar fields from the source's latest JSON response.
3. The selected field's JSON Pointer, data type, current preview, and last update time.
4. A display mode selector.
5. Connection and source status.
6. A refresh action when the selected source has no usable response.

`Value` is available for all scalar types. `Value + sparkline` is enabled only when the current field is numeric. Changing the source clears an incompatible field selection. Settings are saved through the Stream Deck settings API and immediately propagated to the plugin process.

## Key Rendering

Value mode renders only the current scalar value, centered and sized to fit. It does not render the source or field label.

Sparkline mode renders the current value above a subtle line chart based on the last 60 successful numeric samples. The chart scales to the observed minimum and maximum. A flat series is centered vertically rather than producing an invalid range.

Status behavior:

- Fresh value: normal rendering.
- API error with a previous value: keep the value, dim the rendering, and show a small warning indicator.
- MenubarNumbers unavailable with a cached value: keep the cached value with the offline treatment.
- No cached value while offline: render `Offline`.
- Missing JSON Pointer: render `—` with the warning treatment.
- A value configured as a sparkline that becomes non-numeric: render it in value mode until it is numeric again.

Successful API samples append to history only when the selected JSON value is numeric. Failed polls and missing values do not create chart points.

## Data Flow

1. Stream Deck displays an API Data action and loads its saved settings.
2. The plugin discovers the running MenubarNumbers bridge.
3. The plugin registers the active source and JSON Pointer selections.
4. MenubarNumbers adds the selected sources to its existing polling coordinator.
5. A successful API response updates the latest response and appends subscribed numeric values to history.
6. The plugin fetches one batched snapshot and renders all affected keys.
7. When an action disappears or changes settings, the plugin updates the active subscription union.

The plugin refresh loop is independent of remote API intervals: it only reads the latest local snapshot. The remote API continues to be called at the interval configured in MenubarNumbers.

## Lifecycle and Recovery

MenubarNumbers must be running for live updates. The plugin retries discovery and bridge connection with bounded backoff. A newly written discovery file lets it recover after an app restart or port change without reconfiguring keys.

The app persists numeric histories atomically in Application Support. Histories survive app and Stream Deck restarts. Entries remain bounded to 60 samples per subscribed field; histories no longer referenced by a Stream Deck action can be pruned after a conservative retention period defined in the implementation plan.

A malformed discovery or history file is ignored and safely replaced. These files contain no remote API credentials.

## Testing and Verification

Swift tests cover:

- Scalar flattening and RFC 6901 pointer preservation.
- Bridge response allow-listing so request configuration and secrets cannot leak.
- Subscription union behavior with the existing menu-bar layout.
- Numeric sampling, 60-point bounds, persistence, and corrupt-history recovery.
- Loopback authentication and representative bridge responses.

TypeScript tests cover:

- Discovery and bridge client behavior.
- Batched active-action subscriptions.
- Action settings validation and type changes.
- Value, stale, offline, missing, and sparkline SVG rendering.
- Constant, negative, decimal, and short numeric series.

Release verification runs the full Xcode test suite and app build, then plugin lint, tests, build, and package. Manual verification uses multiple Stream Deck keys and exercises source selection, both display modes, API errors, MenubarNumbers restart, Stream Deck restart, and persisted history.

## SDK References

- [Property Inspectors](https://docs.elgato.com/streamdeck/sdk/guides/ui/)
- [Action and global settings](https://docs.elgato.com/streamdeck/sdk/guides/settings/)
- [Key image and title APIs](https://docs.elgato.com/streamdeck/sdk/guides/keys/)
- [Plugin manifest](https://docs.elgato.com/streamdeck/sdk/references/manifest/)
