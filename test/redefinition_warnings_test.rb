# frozen_string_literal: true

require_relative "test_helper"

class RedefinitionWarningsTest < Minitest::Test
  def with_served_dir
    Dir.mktmpdir do |dir|
      Afterburner::RedefinitionWarnings.serve(dir)
      yield File.realpath(dir)
    end
  end

  def test_drops_constant_redefinitions_from_served_files_only
    with_served_dir do |root|
      assert_output(nil, "") { Warning.warn("#{root}/lib/server.rb:4: warning: already initialized constant Server::OPENERS\n") }
      assert_output(nil, "") { Warning.warn("#{root}/lib/server.rb:4: warning: previous definition of OPENERS was here\n") }
      assert_output(nil, /something else/) { Warning.warn("#{root}/lib/server.rb:9: warning: something else\n") }
      assert_output(nil, /already initialized/) { Warning.warn("/elsewhere/x.rb:1: warning: already initialized constant X\n") }
    end
  end

  def test_loading_a_served_file_twice_is_quiet
    with_served_dir do |root|
      file = File.join(root, "lib.rb")
      File.write(file, "module RedefinitionWarningsProbe\n  TABLE = {}.freeze\nend\n")
      assert_output(nil, "") { 2.times { load(file) } }
    end
  ensure
    Object.send(:remove_const, :RedefinitionWarningsProbe) if Object.const_defined?(:RedefinitionWarningsProbe)
  end
end
