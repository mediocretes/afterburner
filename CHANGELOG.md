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
- Copies of the Ruby sources are kept in the save, and `afterburner restore` writes them back into `src/`.
- Double-clickable launchers for macOS and Windows that install what's missing and start everything, with the
  scripts folder set at the top; `AFTERBURNER_SRC` sets it for afterburner too.
- Text files are read as UTF-8 whatever the locale, so afterburner works when started without `LANG`.
- Fixed: a library edited while no script was running stayed stale until afterburner restarted.
- Fixed: `class Float … end` in a script made a new class instead of reopening Ruby's.
- `ns` and `logger` work anywhere in a running script's code, including libraries and methods added to Ruby's
  classes, not only at the script's top level; likewise in the console.
- `AB`, for afterburner's own tools: `AB.functions(pattern)` lists functions with their RAM costs, and
  `AB.doc(name)` shows a function's Ruby call, keyword options, signature, and the game's docs.
- `ns.methods` lists the Ruby names `ns` answers to, and `ns.<Tab>` completes them in the console.
- The console's prompt is a script's top level, so code behaves there as it would in a script. afterburner's
  own classes no longer show through: `Server` at the prompt was afterburner's Remote API server.
- The console claims 80% of the RAM free on the server you run it on, worked out in the game when it starts;
  `--ram` takes a percentage or GB. It says what the game granted, including when that's less than asked.
- Records have `keys`, the snake_case field names, and their `methods` include the field readers, so
  `server.<Tab>` completes fields in the console.
