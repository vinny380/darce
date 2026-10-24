# Browser state failure plan

Written before BrowserCore implementation. These checks protect local browsing state from silent loss or an unusable selection.

1. Archiving deletes a tab, archives a protected favorite/pin, or leaves an archived selection. Exercise today → archive → restore, preserving the original ID and URL; check favorites and pins survive archive attempts.
2. Switching Spaces, moving tabs, or changing tab kinds leaves an invisible selection. Exercise two Spaces, global favorites, moves, and unknown IDs; selection must always be visible or nil.
3. Saving and reopening loses Spaces, tab kinds, navigation updates, or selected IDs. Round-trip the full model through a real temporary filesystem, including a nested destination and a second atomic replacement.
4. Corrupt, future-version, duplicate-ID, or dangling-reference state is silently accepted or overwritten. Read actual files containing each invalid shape, assert failure, and compare original bytes afterward. A missing file alone creates a fresh initial state.

Tests use the public state operations and real filesystem persistence. The UI and WebKit behavior require separate app smoke checks.

## Native shell expansion (before implementation)

The native smoke must verify that folder actions reach disk, resetting a pin actually navigates its retained renderer, split panes never reuse the same WKWebView simultaneously, and an external pinned link opens a temporary Peek without changing the pin's home destination. Same-host links must stay in the pin; intercepting every click would break normal navigation. Closing Peek must leave the original tab and page state intact. Render the shell from a fresh local fixture to a PNG. Drag/drop and keyboard focus require a live UI pass; do not infer their success from model tests.

## Schema v2 expansion (written before implementation)

1. Migration drops old tabs, pinned destinations, archive entries or selection. Decode a literal v1 session and round-trip all identifiers and URL/title/kind values into v2.
2. Folder moves create cycles or cross-Space references; tab moves keep a stale folder. Exercise rejected ancestor/self moves, nested folders and tab movement across Spaces.
3. Navigation silently overwrites a pin's home URL. Navigate a pinned tab, save/reopen, reset and verify original destination.
4. Switching Spaces forgets each selected tab, or ordering loses/duplicates a tab. Switch with multiple tabs in each Space, reorder and round-trip.
5. Automatic archiving hides active/favorite/pinned tabs or destroys history. Exercise an explicit clock and age boundary; protected tabs stay visible and expired tabs restore with their original identity.

## Schema v3 profiles (written before implementation)

1. Migrating v1/v2 loses tabs, folders, selections or assigns a different cookie-store UUID each read. Decode old state twice into a stable default profile, preserve all existing records, then round-trip schema3 on disk.
2. A favorite or remembered selection leaks into another profile. Favorites are shared only among Spaces owned by the same profile; selecting a foreign favorite switches to its owning Space. Reordering cannot cross profile boundaries.
3. Explicit Space reassignment drops data or leaves stale cross-profile favorite selections. `assignSpaceProfile` moves the entire Space, its tabs (including archives), and folder tree to the new profile. URLs and IDs survive; cookie data is never copied by core. The application must recreate renderers whose resolved profile changed. Tab/folder moves between Spaces likewise adopt the destination profile and must recreate the renderer.
4. Corrupt schema3 state silently loses a profile or falls back to another cookie store. Reject missing/duplicate profiles, dangling Space ownership, missing ownership fields and cross-profile remembered selections without modifying file bytes.
