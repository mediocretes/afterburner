# frozen_string_literal: true

require_relative "test_helper"

# main_script? and program_file, against a stand-in for the running script's
# session. The server tests run them in real scripts.
class ScriptAccessTest < Minitest::Test
  FakeSession = Struct.new(:program_file)

  def as_script(program_file)
    Fiber[:afterburner_session] = FakeSession.new(program_file)
    yield
  ensure
    Fiber[:afterburner_session] = nil
  end

  def main_script?(*file) = Object.new.send(:main_script?, *file)
  def program_file = Object.new.send(:program_file)

  def test_outside_a_script_theres_no_program_file
    assert_nil program_file
    refute main_script?
    refute main_script?(__FILE__)
  end

  def test_the_file_defaults_to_the_callers
    as_script(__FILE__) do
      assert_equal __FILE__, program_file
      assert main_script?, "called from this file, which is the program file"
    end
    as_script(File.join(__dir__, "test_helper.rb")) { refute main_script?, "called from this file, which isn't" }
  end

  def test_paths_through_a_symlinked_folder_match_their_real_paths
    Dir.mktmpdir do |dir|
      real = File.join(dir, "real")
      FileUtils.mkdir_p(real)
      File.write(File.join(real, "manager.rb"), "")
      File.write(File.join(real, "other.rb"), "")
      begin
        File.symlink(real, File.join(dir, "src"))
      rescue NotImplementedError, SystemCallError => e # Windows without the right to make one
        skip "can't make a symlink here: #{e.message}"
      end
      as_script(File.join(real, "manager.rb")) do
        assert main_script?(File.join(dir, "src", "manager.rb"))
        refute main_script?(File.join(dir, "src", "other.rb"))
      end
      as_script(File.join(dir, "src", "manager.rb")) { assert main_script?(File.join(real, "manager.rb")) }
    end
  end

  def test_a_file_that_isnt_there_isnt_the_main_script
    as_script(__FILE__) { refute main_script?(File.join(__dir__, "no_such_file.rb")) }
  end
end
