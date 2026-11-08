# frozen_string_literal: true

require_relative "test_helper"

class ConfigTest < Minitest::Test
  def test_defaults_without_filesync_json
    Dir.mktmpdir do |dir|
      config = Afterburner::Config.load(dir)
      assert_equal 12_525, config.port
      assert_equal File.join(File.realpath(dir), "src"), File.join(File.realpath(File.dirname(config.src)), "src")
      assert_nil config.dist, "nothing to sync unless asked"
      assert_equal %w[.js .script .txt], config.extensions
      refute config.allow_deleting
    end
  end

  def test_reads_filesync_json
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, "filesync.json"), JSON.generate(
        port: 13_000, scriptsFolder: "dist", allowedFiletypes: [".js"], allowDeletingFiles: true,
        definitionFile: { location: "types/ns.d.ts" },
      ))
      config = Afterburner::Config.load(dir)
      assert_equal 13_000, config.port
      assert config.dist.end_with?("/dist")
      assert_equal [".js"], config.extensions
      assert config.allow_deleting
      assert config.definitions.end_with?("/types/ns.d.ts")
    end
  end

  def test_filesync_json_without_a_folder_syncs_the_project
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, "filesync.json"), "{}")
      assert_equal File.expand_path(dir), Afterburner::Config.load(dir).dist
    end
  end

  def test_flags_win
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, "filesync.json"), JSON.generate(port: 13_000))
      assert_equal 14_000, Afterburner::Config.load(dir, port: 14_000).port
    end
  end
end
