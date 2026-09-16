# Multi-display tiling

## Goal

Make `td tile` work reliably on a single display and on an extended desktop, with each connected display laid out independently.

## Scope

- Discover the usable bounds of every connected display.
- Associate each visible iTerm and supported browser window with the display containing most of that window.
- Preserve every iTerm window's current display.
- Tile each display's iTerm windows as a separate grid.
- Use the frontmost supported browser already on a display as that display's main window.
- Give displays without a browser a full terminal grid.
- Preserve `--gap`, `--main-size`, and `--no-main`, and make the documented `--with` option effective.
- Rehydrate the offloaded `td` launcher without overwriting its newer local `awake` command so tiling can be exercised end to end.

Out of scope:

- Moving windows between displays.
- Adding interactive display selection.
- Tiling applications other than iTerm and the existing supported browsers.
- Repairing unrelated Git metadata or other offloaded files in the workspace.

## Chosen design

Use one CoreGraphics/AppKit discovery pass to emit each display's usable frame and each visible window's display assignment. Assign a window to the display with which it has the greatest intersection area. Then invoke the existing layout operation once per display, using that display's coordinates and only its iTerm/browser windows.

This keeps current-Space discovery, works with negative display coordinates, respects per-display menu bar and Dock insets, and prevents layouts from pulling windows onto the primary display.

## A-Z build list

1. Rehydrate the `td` launcher and verify its existing local additions are preserved.
2. Replace primary-screen-only discovery with structured screen and window discovery.
3. Group iTerm and browser windows by display in Bash.
4. Select the frontmost supported browser independently for each display.
5. Pass each display's usable origin and dimensions into the layout operation.
6. Make browser placement target the discovered browser window rather than always `window 1`.
7. Parse and honor `--with` while preserving the existing flags.
8. Add fixture-driven tests for single-display and extended-display grouping.
9. Run Bash syntax checks, the tile regression tests, and the existing test suite.
10. Dogfood discovery and `td tile` against the live desktop without moving windows across displays.

## Done criteria

- `td tile` invokes one independent layout per display containing visible iTerm windows.
- An iTerm window is never included in another display's layout.
- Different display origins and sizes are passed through unchanged, including negative coordinates.
- Browser selection and `--no-main` are independent per display.
- `--with` selects only the requested supported browser.
- A display with no browser uses its complete usable frame for terminals.
- Existing grid dimensions remain unchanged; no-browser layouts fill the display's usable frame as documented.
- Automated regression tests cover the grouping contract and pass.
- The launcher executes and live discovery produces valid display/window assignments.
