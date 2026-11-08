# frozen_string_literal: true

require "json"

module Afterburner
  # Settings. afterburner reads filesync.json if there is one, so it can stand
  # in for bitburner-filesync (as in the official TypeScript template) without
  # new configuration; flags override it.
  Config = Data.define(:port, :src, :dist, :extensions, :exclude, :allow_deleting, :definitions, :costs) do
    DEFAULT_PORT = 12_525

    def self.load(dir = Dir.pwd, **flags)
      file = File.join(dir, "filesync.json")
      json = File.exist?(file) ? JSON.parse(File.read(file)) : nil
      json_dist = json && (json["scriptsFolder"] || ".")
      new(
        port: flags[:port] || json&.dig("port") || DEFAULT_PORT,
        src: File.expand_path(flags[:src] || "src", dir),
        dist: (flags[:dist] || json_dist)&.then { File.expand_path(_1, dir) },
        extensions: json&.dig("allowedFiletypes") || %w[.js .script .txt],
        exclude: json&.dig("exclude") || %w[.vscode .idea .github],
        allow_deleting: json&.dig("allowDeletingFiles") || false,
        definitions: File.expand_path(flags[:definitions] || json&.dig("definitionFile", "location") || "NetscriptDefinitions.d.ts", dir),
        costs: File.expand_path(flags[:costs] || ".afterburner/ram-costs.json", dir),
      )
    end
  end
end
