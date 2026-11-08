# frozen_string_literal: true

require "fileutils"
require "json"

module Afterburner
  # RAM costs as the game itself reports them, cached in a file.
  #
  # The documented costs in NetscriptDefinitions.d.ts are right for nearly
  # every function, but some depend on the player's progress, and the docs
  # can't say which value applies to you. ns.getFunctionRamCost can, and it's
  # free to call, so when a script starts the daemon asks the game for every
  # function's cost (at most once a minute) and saves them here. The builder
  # prefers these, and rebuilds stubs when they change.
  class RamCosts
    REFRESH_SECONDS = 60

    attr_reader :path

    def initialize(path)
      @path = path
      @checked_at = nil
    end

    def load
      File.exist?(@path) ? JSON.parse(File.read(@path)) : {}
    rescue JSON::ParserError
      {}
    end

    # True at most once per REFRESH_SECONDS; the caller is expected to measure.
    def due?
      return false if @checked_at && Time.now - @checked_at < REFRESH_SECONDS

      @checked_at = Time.now
      true
    end

    def save(costs)
      sorted = costs.sort.to_h
      return if sorted == load

      FileUtils.mkdir_p(File.dirname(@path))
      File.write(@path, "#{JSON.pretty_generate(sorted)}\n")
    end
  end
end
