# frozen_string_literal: true

require_relative "test_helper"

# Ruby on Windows writes files in text mode unless told otherwise, turning
# every "\n" into "\r\n", so a file afterburner writes there would differ from
# the same file written on a Mac. afterburner writes files with
# Afterburner.write_text (File.binwrite) instead.
class LineEndingsTest < Minitest::Test
  # A write in text mode: File.write, IO.write, or an open/new with a mode
  # string like "w", "a+" or "w:UTF-8" (no "b").
  TEXT_MODE_WRITE = /\b(?:File|IO)\.write\b|\b(?:open|new)\(.*["'][wa]\+?t?(?::[\w-]+){0,2}["']/

  # The byte checks (below, and in source_backup_test and server_test) can only
  # fail on Windows. This one fails anywhere.
  def test_nothing_writes_files_in_text_mode
    root = File.expand_path("..", __dir__)
    found = Dir[File.join(root, "{lib/**/*.rb,exe/afterburner}")].flat_map do |file|
      File.foreach(file).with_index(1).filter_map do |line, number|
        next if line.lstrip.start_with?("#") || !line.match?(TEXT_MODE_WRITE)

        "#{file.delete_prefix("#{root}/")}:#{number}: #{line.strip}"
      end
    end
    assert_empty found, "write files with Afterburner.write_text, which keeps LF on Windows"
  end

  def test_ram_costs_keep_lf
    Dir.mktmpdir do |dir|
      path = File.join(dir, ".afterburner", "ram-costs.json")
      Afterburner::RamCosts.new(path).save("hack" => 0.1, "grow" => 0.15)
      # binread: File.read on Windows turns CRLF back into LF, which would hide a CRLF write.
      assert_equal %({\n  "grow": 0.15,\n  "hack": 0.1\n}\n), File.binread(path)
    end
  end
end
