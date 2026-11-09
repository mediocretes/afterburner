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
  `--ram` takes a percentage or GB, and the console says how much it got.
- Records have `keys`, the snake_case field names, and their `methods` include the field readers, so
  `server.<Tab>` completes fields in the console.
- Fixed: `ns.public_send(:name, ...)` and `ns.send` raised `NoMethodError`, though the RAM scan charged them.
- Fixed: Ruby's "already initialized constant" warnings reached a script's terminal when a library was loaded
  again, as after a reload that failed.
- Fixed: reopening a class from a library you had just loaded (`require_relative 'lib/server'`, then
  `class Server … end`) made a new, empty class instead, in a script the first time that library loaded and at
  the console prompt.
- Restarting afterburner no longer stops Ruby scripts. Each waits for it, then starts again from the top in the
  same process; one log line counts them. When the game connects, copies of the proxy on other servers are
  brought up to date, so scripts there resume too. Scripts restarted by a loading save now wait for afterburner
  however long it takes, not just a minute.
- Fixed: `require_relative` at the console prompt looked in afterburner's own folder. It now resolves against
  the scripts folder, so `require_relative 'lib/server'` works there as it does in a script.
