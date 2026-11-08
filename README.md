# afterburner

Write [Bitburner](https://github.com/bitburner-official/bitburner-src) scripts in Ruby.
(afte**rb**urner: the rb is right there in the middle.)

```ruby
# src/scout.rb — run it in the game as: run scout.js n00dles
target = ARGV.first || "n00dles"
ns.nuke(target) unless ns.root_access?(target)

server = ns.server(target)
puts "#{target}: #{ns.format.number(server.money_max)} max, security #{server.min_difficulty}"
logger.info "scouted #{target}"
```

afterburner is one local process that:

- **serves the game's Remote API**, syncing your files into the game the way
  [bitburner-filesync](https://github.com/bitburner-official/bitburner-filesync) does (it replaces it);
- **runs your `.rb` scripts in real Ruby** (MRI: gems, `debug`, your own editor);
- **gives the game a small JavaScript stub for each one**, which claims the script's RAM and makes its `ns` calls.

From the game's side, `scout.rb` is just `scout.js`: `run`, `kill`, `ps`, threads, and RAM all work as
usual, and the game charges a Ruby script for the functions it calls, exactly as it would JavaScript.

## Quick start

You need Ruby 3.4 or newer and Bitburner v3.

```ruby
# Gemfile
gem "afterburner", github: "mediocretes/afterburner"
```

```sh
bundle install
mkdir src && echo 'puts "Hello from Ruby #{RUBY_VERSION}!"' > src/hello.rb
bundle exec afterburner watch
```

Then, in the game:

1. **Options → Remote API**: port `12525`, then **Connect**. In Chrome, allow the site's local network access when
   asked. (Chrome requires that for any tool on your machine, bitburner-filesync included.)
2. While you're there, set **Reconnection delay** to a few seconds, so the game reconnects by itself whenever you
   restart afterburner.
3. `run hello.js`

### With the TypeScript template

If you use the official [typescript-template](https://github.com/bitburner-official/typescript-template),
afterburner reads its `filesync.json` and takes over from bitburner-filesync. In `package.json`, swap
`bitburner-filesync` for `bundle exec afterburner watch`. `tsc` keeps compiling `src/*.ts` into `dist/`;
afterburner syncs `dist/` and runs `src/*.rb`.

## Writing Ruby scripts

Each file under `src/` is a script (`src/tools/scan.rb` runs as `tools/scan.js`), except files under a `lib/`
folder, which are libraries for scripts to `require_relative`.

**`ns`** has every Netscript function, under Ruby names:

```ruby
ns.hack("n00dles")                        # ns.hack
ns.server_max_money("n00dles")            # ns.getServerMaxMoney: snake_case, get_ dropped
ns.root_access?("n00dles")                # ns.hasRootAccess: questions get a ?
ns.hacknet.num_nodes                      # namespaces
ns.hack("n00dles", additional_msec: 50)   # options as keyword arguments
ns.getServerMaxMoney("n00dles")           # the JavaScript names work too
```

Functions that act and report whether it worked (`nuke`, `scp`, `kill`) keep plain names. A typo raises
`NoMethodError` with suggestions.

**Game objects** come back as records with snake_case readers:

```ruby
server = ns.server("n00dles")
server.money_max          # moneyMax
server.admin_rights?      # hasAdminRights
server[:money_max]        # same thing
server.to_h               # { hostname: "n00dles", money_max: 1750000, ... }

case server
in { has_admin_rights: false } then ns.nuke(server.hostname)
in { money_max: 0 } then logger.info "nothing to take"
end
```

**Output:** `puts`, `print`, `p`, and `warn` go to the game's terminal, from anywhere in your code. `logger`
writes to the script's log window (`ns.ui.open_tail` shows it).

**Also there:** `ARGV` (the script's arguments), `exit`, `abort("why")`, `at_exit { }`, and Ruby's own
`sleep` alongside `ns.sleep(ms)`. Errors from the game raise `NetscriptError`, which you can rescue; an
uncaught Ruby exception shows up in the game's error dialog with its backtrace. Scripts can `require` any gem
in your Gemfile.

## Hot reload

Save a script while it's running and afterburner restarts it in place: same pid, same arguments, new code,
with `afterburner: reloaded` in its log. The old code's `at_exit` blocks run first. Saving a library under
`lib/` reloads it and restarts the scripts that use it.

The game won't let a running script use more RAM than it started with, and it counts every function the
process has called, old code included. So if the new code would need more than the stub claimed, afterburner
leaves the old code running and says so; run the script again to pick up the change. A reload also waits for
any `ns` call in progress (a `hack`, say) to finish. `--no-reload` turns it off.

## Commands

| | |
|---|---|
| `afterburner watch` | Serve the game: sync files, run Ruby scripts. Leave it running. |
| `afterburner console [--ram GB]` | IRB with `ns` live in the game. It pushes `afterburner/console.js`, which claims `--ram` GB (default 4); run that in the game and type away. The game charges each new function you call against the claim. |
| `afterburner save [FILE]` | Download the game's live save, as the in-game export would. |
| `afterburner ram FILE...` | RAM a script needs: `.rb` files are scanned locally, with a breakdown; anything else is the game's own figure. |
| `afterburner stub FILE.rb` | Print the JavaScript stub the game runs for a script. |

Options: `--port`, `--src` (Ruby scripts; default `src`), `--dist` (other files to sync; default from
`filesync.json`, or none), `--definitions`, `--costs`, `--no-reload`, `--origin URL` (accept the game from
another address), and `--verbose` (log every message to and from scripts, for bug reports). Run
`afterburner --help` for details.

## RAM

The game charges every script 1.6 GB plus the cost of each distinct function it uses, and it stops a script
that calls a function it wasn't charged for. So afterburner works out each Ruby script's RAM the way the game
does for JavaScript, by reading the source (with [Prism](https://github.com/ruby/prism)): it counts calls made
through `ns`, `@ns`, or a variable holding a namespace (`hacknet = ns.hacknet`), and follows `require_relative`.
`afterburner ram src/scout.rb` shows the breakdown.

A call it can't see (a name built at runtime, say) isn't charged, and the game stops the script when it makes
that call, with a note explaining why.

The game's documentation is a little off for some functions whose cost depends on your progress. So when a
script starts, afterburner also asks the game what each function actually costs (that's free), caches the
answers in `.afterburner/`, and updates any stub whose number changes.

## Security

Giving the game local network access means any script in it can reach your machine, and afterburner runs Ruby.
So afterburner listens on localhost only; takes connections only from the game's own pages (another website in
the same browser can't drive it); runs only `.rb` files under `src/`, by plain relative name; and never evaluates
code the game sends. The console, `save`, and `ram` refuse browser connections entirely. It's not a sandbox for the
Ruby you write: that's your code, on your machine.

## Platforms

- **Web build, in Chrome**: tested. Needs the local network permission.
- **Steam build**: should work, with no permission needed, but not tested yet. If afterburner logs
  `refused a connection from …`, please open an issue with that origin.
- **Windows**: nothing is deliberately Unix-only (pure Ruby, polling file watch), but it's untested.

## Limits

- A Ruby loop that never waits (no `ns` call, `sleep`, or IO) stalls every Ruby script, the way a JavaScript loop
  without `await` freezes the game; killing it in the game can't interrupt it.
- One game at a time: a second game connecting (another browser tab, say) takes over from the first.
- A game object's field whose name is also a Ruby method (`hash`, `class`, `display`) has to be read as
  `record[:hash]`.
- Reloading the game stops all running Ruby scripts.
- Functions that take callbacks or return objects with methods (`ns.get_port_handle`, React-node printers) don't
  cross over, except `ns.at_exit { }`, which runs in Ruby.
- Each running Ruby script holds one WebSocket. That's fine for scripts that make decisions; workers you run at
  hundreds of threads are better left as three-line JavaScript files.

## How it works

See [DESIGN.md](DESIGN.md): the architecture, both protocols, how RAM is worked out, and what's next.

## Development

```sh
bundle install
bundle exec rake test     # unit tests, a few seconds
```

The end-to-end test drives the live web game in a headless browser, with a fresh save in its own profile:

```sh
(cd test/e2e && npm install && npx playwright install chromium)
bundle exec rake e2e
```

## License

MIT. Bitburner is by its own authors and isn't affiliated with this project.
