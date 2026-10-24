# Native prototype acceptance scenarios

Written before UI implementation. The state/store regression plan lives in FAILURE_MODES.md.

1. A real WebKit page loads, its title reaches tab state, and JavaScript state survives switching away and back. Artifact: app-driven smoke JSON with each result.
2. Switching Spaces must not expose another Space's Today tabs. A favorite remains visible in both. Archiving then restoring a Today tab must preserve its identity and URL.
3. Saving/reopening a real session file must reproduce state. Corrupt or future-version data must not be silently replaced. Core tests cover the file-level cases; UI must disable writes after load failure.
4. A `javascript:` or `file:` address must not execute through the address bar; search text must encode as a query. Native navigation failure must be visible and recoverable.
5. The native window supports Cmd+L/T/W, tab context menus, adding/switching Spaces, and native back/forward/reload controls. Inspect the running app and retain a screenshot; do not count a screenshot as proof of all interactions.

This is an interaction prototype using system WebKit. Chromium/Chrome extension compatibility, multi-profile website storage, downloads, sync, durable navigation history, and security-release packaging are outside this build's acceptance boundary.
