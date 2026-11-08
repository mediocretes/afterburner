# frozen_string_literal: true

# afterburner: write Bitburner scripts in Ruby. See README.md and DESIGN.md.
module Afterburner
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
require_relative "afterburner/source_backup"
require_relative "afterburner/server"
require_relative "afterburner/console"
