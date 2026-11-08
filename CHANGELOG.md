# Changelog

## 0.1.0 (unreleased)

First version.

- `afterburner watch`: serves the game's Remote API (replacing bitburner-filesync, and reading its
  `filesync.json`), syncs files, and runs `src/**/*.rb` as Ruby scripts through generated stubs.
- RAM worked out from the source with Prism, corrected by costs measured in the game.
- A Ruby-shaped `ns`: snake_case, `?` predicates, keyword options, records, `ARGV`, `puts` and `logger`.
- `afterburner console`, `save`, `ram`, and `stub`.
