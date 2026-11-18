# frozen_string_literal: true

require_relative "test_helper"

# Ruby on Windows writes files in text mode unless told otherwise, turning
# every "\n" into "\r\n", so a file afterburner writes there would differ from
# the same file written on a Mac. These check the bytes it writes. (The
# restored scripts and the definitions file are checked in source_backup_test
# and server_test.)
class LineEndingsTest < Minitest::Test
  def test_ram_costs_keep_lf
    Dir.mktmpdir do |dir|
      path = File.join(dir, ".afterburner", "ram-costs.json")
      Afterburner::RamCosts.new(path).save("hack" => 0.1, "grow" => 0.15)
      # binread: File.read on Windows turns CRLF back into LF, which would hide a CRLF write.
      assert_equal %({\n  "grow": 0.15,\n  "hack": 0.1\n}\n), File.binread(path)
    end
  end
end
