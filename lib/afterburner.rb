# frozen_string_literal: true

# afterburner: write Bitburner scripts in Ruby. See README.md and DESIGN.md.
module Afterburner
  # Reads a text file as UTF-8 whatever the locale says. Login agents start
  # without LANG, which makes Ruby assume US-ASCII, and the game's definitions
  # file isn't ASCII.
  def self.read_text(path) = File.read(path, encoding: Encoding::UTF_8)
end

require_relative "afterburner/version"
require_relative "afterburner/api"
require_relative "afterburner/record"
require_relative "afterburner/ns"
require_relative "afterburner/scripts"
require_relative "afterburner/ram_costs"
require_relative "afterburner/ram_scanner"
require_relative "afterburner/session"
require_relative "afterburner/script_context"
require_relative "afterburner/config"
require_relative "afterburner/game_link"
require_relative "afterburner/file_sync"
require_relative "afterburner/stubs"
require_relative "afterburner/server"
require_relative "afterburner/console"
require_relative "afterburner/autostart"
