# frozen_string_literal: true

require "json"

module Afterburner
  class ConfigError < StandardError; end

  # Settings. afterburner reads filesync.json if there is one, so it can stand
  # in for bitburner-filesync (as in the official TypeScript template) without
  # new configuration; flags override it. AFTERBURNER_SRC sets the scripts
  # folder too, for when afterburner is started through something else (the
  # launchers set it on their way through `npm run watch`).
  Config = Data.define(:port, :src, :dist, :extensions, :exclude, :allow_deleting, :definitions, :costs, :reload, :origins) do
    DEFAULT_PORT = 12_525
    # Never synced, whatever filesync.json says: syncing them would be slow or wrong.
    ALWAYS_EXCLUDE = %w[node_modules .git .afterburner].freeze

    def self.load(dir = Dir.pwd, **flags)
      json = read_filesync(dir)
      json_dist = json && (json["scriptsFolder"] || ".")
      new(
        port: flags[:port] || json&.dig("port") || DEFAULT_PORT,
        src: File.expand_path(flags[:src] || ENV.fetch("AFTERBURNER_SRC", "").then { _1.empty? ? nil : _1 } || "src", dir),
        dist: (flags[:dist] || json_dist)&.then { File.expand_path(_1, dir) },
        extensions: json&.dig("allowedFiletypes") || %w[.js .script .txt],
        exclude: (json&.dig("exclude") || %w[.vscode .idea .github]) | ALWAYS_EXCLUDE,
        allow_deleting: json&.dig("allowDeletingFiles") || false,
        definitions: File.expand_path(flags[:definitions] || json&.dig("definitionFile", "location") || "NetscriptDefinitions.d.ts", dir),
        costs: File.expand_path(flags[:costs] || ".afterburner/ram-costs.json", dir),
        reload: flags.fetch(:reload, true),
        origins: Array(flags[:origins]),
      )
    end

    def self.read_filesync(dir)
      file = File.join(dir, "filesync.json")
      return nil unless File.exist?(file)

      json = JSON.parse(File.read(file))
      raise ConfigError, "#{file} should hold a JSON object" unless json.is_a?(Hash)

      json
    rescue JSON::ParserError => e
      raise ConfigError, "#{file} isn't valid JSON: #{e.message.lines.first&.strip}"
    end
  end
end
