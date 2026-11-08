# Changelog

## 0.1.0 (unreleased)

First version.

- `afterburner watch`: serves the game's Remote API (replacing bitburner-filesync, and reading its
  `filesync.json`), syncs files, and runs `src/**/*.rb` as Ruby scripts through generated stubs.
- RAM worked out from the source with Prism, corrected by costs measured in the game.
- A Ruby-shaped `ns`: snake_case, `?` predicates, keyword options, records, `ARGV`, `puts` and `logger`.
- Hot reload: saving a running script restarts it in place when its RAM claim allows; saving a library
  reloads it and restarts the scripts that use it.
- `afterburner console`, `save`, `ram`, and `stub`.
- `--verbose`, `--origin`, and `--no-reload`.
- Scripts restarted by a loading save wait for afterburner rather than failing.
- Text files are read as UTF-8 whatever the locale, so afterburner works when started without `LANG`.
