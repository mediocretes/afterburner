# frozen_string_literal: true

require_relative "test_helper"

class ConsoleTest < Minitest::Test
  include FixtureApi

  def setup
    @console = Afterburner::Console.new(port: 0, ram: 4, definitions: "unused")
    @ns = Afterburner::NS.new(@console, api)
    @prompt = @console.prompt_binding(@ns)
  end

  def at_prompt(code) = @prompt.eval(code)

  def test_the_prompt_is_a_scripts_top_level
    assert_equal "main", at_prompt("self").to_s
    assert_equal [], at_prompt("ARGV")
    assert_same Afterburner::NetscriptError, at_prompt("NetscriptError")
    assert_same AB, at_prompt("AB")
  end

  def test_afterburners_own_classes_stay_out_of_the_way
    assert_nil at_prompt("defined?(Server)")
    assert_nil at_prompt("defined?(Record)")
    at_prompt("class Server; def self.mine? = true; end")
    assert at_prompt("Server.mine?")
    refute_respond_to Afterburner::Server, :mine?
  end

  def test_reopening_a_ruby_class_reopens_the_real_one
    at_prompt("class Integer; def afterburner_prompt_test = :reopened; end")
    assert_equal :reopened, 1.afterburner_prompt_test
  ensure
    Integer.remove_method(:afterburner_prompt_test) if Integer.method_defined?(:afterburner_prompt_test)
  end

  # A class required at the prompt didn't exist when the prompt was built;
  # `class Name` afterwards must reopen it, not hide it behind an empty one.
  def test_a_class_required_at_the_prompt_can_be_reopened_there
    Dir.mktmpdir do |src|
      FileUtils.mkdir_p(File.join(src, "lib"))
      File.write(File.join(src, "lib", "probe.rb"), "class PromptReopenProbe\n  def initialize(host) = @host = host\nend\n")
      prompt = Afterburner::Console.new(port: 0, ram: 4, definitions: "unused", src:).prompt_binding(@ns)
      prompt.eval("require_relative 'lib/probe'")
      prompt.eval("class PromptReopenProbe\n  def host = @host\nend")
      assert_same Object.const_get(:PromptReopenProbe), prompt.eval("PromptReopenProbe")
      assert_equal "iron-gym", prompt.eval("PromptReopenProbe.new('iron-gym').host")
    end
  ensure
    Object.send(:remove_const, :PromptReopenProbe) if Object.const_defined?(:PromptReopenProbe)
  end

  def test_load_at_the_prompt_shares_classes_too
    Dir.mktmpdir do |dir|
      file = File.join(dir, "loaded.rb")
      File.write(file, "class PromptLoadProbe; end\n")
      at_prompt("load #{file.inspect}")
      assert_same Object.const_get(:PromptLoadProbe), at_prompt("class PromptLoadProbe; self; end")
    end
  ensure
    Object.send(:remove_const, :PromptLoadProbe) if Object.const_defined?(:PromptLoadProbe)
  end

  # A script paused inside its own wrapped load (waiting on an ns call) leaves
  # the thread's top-level wrapper pointing at its module; a plain Kernel#load
  # then would put the file's classes there instead of at the top level.
  def test_load_reaches_the_top_level_while_a_script_is_paused_mid_load
    Dir.mktmpdir do |dir|
      paused = File.join(dir, "paused.rb")
      File.write(paused, "Fiber.yield\n")
      script = Fiber.new { load(paused, Module.new) }
      script.resume # now paused inside its wrapped load
      file = File.join(dir, "probe.rb")
      File.write(file, "class PausedLoadProbe; end\n")
      at_prompt("load #{file.inspect}")
      assert Object.const_defined?(:PausedLoadProbe, false), "the class landed in the paused script's module"
      script.resume
    end
  ensure
    Object.send(:remove_const, :PausedLoadProbe) if Object.const_defined?(:PausedLoadProbe, false)
  end

  def test_a_class_the_prompt_defines_first_stays_its_own
    at_prompt("class PromptOwnProbe; end")
    refute Object.const_defined?(:PromptOwnProbe)
  end

  def test_methods_defined_at_the_prompt_dont_leak
    at_prompt("def helper = 42")
    assert_equal 42, at_prompt("helper")
    refute Object.private_method_defined?(:helper)
  end

  def test_ns_is_a_local_so_irb_can_complete_it
    assert_includes @prompt.local_variables, :ns
    assert_same @ns, at_prompt("ns")
  end

  def test_require_relative_resolves_against_the_scripts_folder
    Dir.mktmpdir do |src|
      FileUtils.mkdir_p(File.join(src, "lib"))
      File.write(File.join(src, "lib", "prompt_helper.rb"), "module PromptRequireProbe\n  def self.tag = :from_src\nend\n")
      prompt = Afterburner::Console.new(port: 0, ram: 4, definitions: "unused", src:).prompt_binding(@ns)
      assert prompt.eval("require_relative 'lib/prompt_helper'")
      assert_equal :from_src, prompt.eval("PromptRequireProbe.tag")
      refute prompt.eval("require_relative 'lib/prompt_helper'"), "loaded once, as require does"
    end
  ensure
    Object.send(:remove_const, :PromptRequireProbe) if Object.const_defined?(:PromptRequireProbe)
  end

  def test_require_relative_is_rubys_own_without_a_scripts_folder
    assert_raises(LoadError) { at_prompt("require_relative 'lib/nothing_here'") }
  end

  def with_src
    Dir.mktmpdir do |src|
      FileUtils.mkdir_p(File.join(src, "lib"))
      console = Afterburner::Console.new(port: 0, ram: nil, definitions: "unused", src:, out: StringIO.new)
      yield src, console, console.prompt_binding(@ns)
    end
  end

  # The common case: require, edit, then the next command.
  def test_an_edit_right_after_the_require_is_picked_up
    with_src do |src, console, prompt|
      file = File.join(src, "lib", "edit_probe.rb")
      File.write(file, "class EditProbe\n  def version = 1\nend\n")
      prompt.eval("require_relative 'lib/edit_probe'")
      console.note_loaded_files # after the require's command
      File.write(file, "class EditProbe\n  def version = 2\nend\n")
      File.utime(Time.now + 5, Time.now + 5, file)
      console.reload_changed_files # before the next command
      assert_equal 2, prompt.eval("EditProbe.new.version")
    end
  ensure
    Object.send(:remove_const, :EditProbe) if Object.const_defined?(:EditProbe)
    $LOADED_FEATURES.reject! { _1.end_with?("lib/edit_probe.rb") }
  end

  def test_load_at_the_prompt_resolves_against_the_scripts_folder
    with_src do |src, _console, prompt|
      File.write(File.join(src, "lib", "loaded_probe.rb"), "class PromptLoadResolveProbe; end\n")
      prompt.eval("load 'lib/loaded_probe'")
      assert_same Object.const_get(:PromptLoadResolveProbe), prompt.eval("PromptLoadResolveProbe")
    end
  ensure
    Object.send(:remove_const, :PromptLoadResolveProbe) if Object.const_defined?(:PromptLoadResolveProbe)
  end

  def test_a_changed_library_is_reloaded_before_the_next_command
    with_src do |src, console, prompt|
      file = File.join(src, "lib", "reload_probe.rb")
      File.write(file, "class ReloadProbe\n  def version = 1\nend\n")
      prompt.eval("require_relative 'lib/reload_probe'")
      console.note_loaded_files # as after each command
      assert_equal 1, prompt.eval("ReloadProbe.new.version")

      File.write(file, "class ReloadProbe\n  def version = 2\nend\n")
      File.utime(Time.now + 5, Time.now + 5, file)
      console.reload_changed_files
      assert_equal 2, prompt.eval("ReloadProbe.new.version")
      assert_includes console.instance_variable_get(:@out).string, "(reloaded lib/reload_probe.rb)"

      File.write(file, "class ReloadProbe\n  def version = \nend\n")
      File.utime(Time.now + 10, Time.now + 10, file)
      console.reload_changed_files
      assert_equal 2, prompt.eval("ReloadProbe.new.version"), "a file that won't load leaves the previous version"
      assert_match(/reloading lib\/reload_probe\.rb failed, so the previous version stays/, console.instance_variable_get(:@out).string)
    end
  ensure
    Object.send(:remove_const, :ReloadProbe) if Object.const_defined?(:ReloadProbe)
    $LOADED_FEATURES.reject! { _1.end_with?("lib/reload_probe.rb") }
  end

  def test_at_exit_says_its_for_scripts
    error = assert_raises(ArgumentError) { at_prompt("at_exit { }") }
    assert_match(/for scripts/, error.message)
  end
end
