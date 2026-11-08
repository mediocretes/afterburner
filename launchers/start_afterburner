#!/bin/bash
# Start afterburner: everything this Bitburner scripts project needs, running
# in this window. Double-click it in Finder; close the window (or press
# Ctrl-C) to stop. Keep it in your project folder, next to your Gemfile.
#
# It installs anything missing (bundle install, and npm install for the
# TypeScript template), then runs `npm run watch` if package.json has a watch
# script (the TypeScript template: compiler, file sync, and afterburner), or
# else `afterburner watch`.

# The folder whose files become the game's home folder. With "src",
# src/hello.rb runs in the game as `run hello.js`.
SCRIPTS="src"

cd "$(dirname "$0")" || exit 1
trap 'echo; read -r -p "afterburner has stopped. Press Return to close this window." _' EXIT

# A double-clicked file may not get your shell's setup, so look where Homebrew
# and version managers usually live, and use their Ruby and Node if there.
export PATH="/opt/homebrew/bin:/usr/local/bin:$HOME/.local/bin:$PATH"
if command -v mise >/dev/null; then
  eval "$(mise env -s bash)"
elif command -v rbenv >/dev/null; then
  eval "$(rbenv init - bash)"
fi

if ! command -v bundle >/dev/null || ! ruby -e 'exit(Gem::Version.new(RUBY_VERSION) >= Gem::Version.new("3.4"))' 2>/dev/null; then
  echo "afterburner needs Ruby 3.4 or newer, with bundler. This window has: $(ruby -v 2>/dev/null || echo 'no Ruby')"
  exit 1
fi

echo "Starting afterburner in $PWD (scripts in $SCRIPTS/)"
bundle check >/dev/null 2>&1 || bundle install || exit 1

if [ -f package.json ] && grep -q '"watch"' package.json; then
  [ -d node_modules ] || npm install || exit 1
  AFTERBURNER_SRC="$SCRIPTS" npm run watch
else
  bundle exec afterburner watch --src "$SCRIPTS"
fi
