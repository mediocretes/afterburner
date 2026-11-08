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

  def test_methods_defined_at_the_prompt_dont_leak
    at_prompt("def helper = 42")
    assert_equal 42, at_prompt("helper")
    refute Object.private_method_defined?(:helper)
  end

  def test_ns_is_a_local_so_irb_can_complete_it
    assert_includes @prompt.local_variables, :ns
    assert_same @ns, at_prompt("ns")
  end

  def test_at_exit_says_its_for_scripts
    error = assert_raises(ArgumentError) { at_prompt("at_exit { }") }
    assert_match(/for scripts/, error.message)
  end
end
