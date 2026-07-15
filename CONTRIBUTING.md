# Contributing

Thanks for helping improve codexU.

## Development

Build the app:

```sh
make build
```

Run the global shortcut validation and exclusive-conflict self-test:

```sh
build/codexU.app/Contents/MacOS/codexU --self-test-global-shortcut
```

Run palette package validation and rendering tests:

```sh
make test-palettes
./scripts/test-status-item.sh
```

Run locally:

```sh
make run
```

Check the local data reader:

```sh
make probe
```

## Pull Requests

- Keep changes focused on one bug fix or feature.
- Run `make build` before opening a pull request.
- Update `README.md` or `DISTRIBUTION.md` when behavior, installation, permissions, or packaging changes.
- Avoid committing local build outputs from `build/` or `dist/`.

## Palette Contributions

Palette contributions are declarative packages under `Resources/Palettes/<stable-id>/`; do not add palette-specific branches to Swift views. A package must include light and dark semantic tokens, Chinese and English metadata, source/license information, and an asset manifest. SVG assets are optional and must stay within the static safety subset.

Before opening a palette PR:

- Follow [Palette Package v1](docs/PALETTE_PACKAGES.md).
- Verify both Light and Dark appearances in the 820 × 720 main window, settings window, Runtime popover, and all three menu-bar density modes.
- Run `make test-palettes` and `./scripts/test-status-item.sh`.
- Include screenshots for both appearances and explain the cultural/design source without claiming unsupported artifact accuracy.
- Keep status, surface, text, and control colors unchanged; a palette may only provide the public configurable roles.

## Privacy

codexU reads local Codex files from `~/.codex/`. Do not include real account data, thread titles, local paths, screenshots with private task names, or local SQLite data in issues or pull requests.
