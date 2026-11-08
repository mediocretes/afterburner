# frozen_string_literal: true

require_relative "test_helper"

class RamScannerTest < Minitest::Test
  include FixtureApi

  def scan(source, extra = {})
    Dir.mktmpdir do |dir|
      extra.each do |name, text|
        FileUtils.mkdir_p(File.dirname(File.join(dir, name)))
        File.write(File.join(dir, name), text)
      end
      File.write(File.join(dir, "script.rb"), source)
      Afterburner::RamScanner.new(api).scan(File.join(dir, "script.rb"))
    end
  end

  def charged(source, extra = {}) = scan(source, extra).charges.map(&:name)

  def test_base_cost_only
    assert_in_delta 1.6, scan("puts 'hi'").ram
  end

  def test_counts_each_function_once
    result = scan("ns.hack('a'); ns.hack('b'); ns.server_max_money('a')")
    assert_equal %w[getServerMaxMoney hack], result.charges.map(&:name)
    assert_in_delta 1.8, result.ram
  end

  def test_every_spelling_costs_the_same
    assert_equal ["hasRootAccess"], charged("ns.root_access?(t); ns.has_root_access?(t); ns.hasRootAccess(t)")
  end

  def test_namespaces
    assert_equal ["hacknet.numNodes"], charged("ns.hacknet.num_nodes")
  end

  def test_ns_as_an_argument_or_instance_variable
    source = <<~RUBY
      def helper(ns) = ns.hacking_level
      class Farm
        def initialize(ns) = @ns = ns
        def go = @ns.hack("n00dles")
      end
    RUBY
    assert_equal %w[getHackingLevel hack], charged(source)
  end

  def test_namespace_and_ns_aliases
    assert_equal ["hacknet.numNodes"], charged("hacknet = ns.hacknet\nhacknet.num_nodes")
    assert_equal ["hack"], charged("n = ns\nn.hack('x')")
  end

  def test_send_with_a_literal_name
    assert_equal ["hack"], charged("ns.public_send(:hack, 'x')")
    assert_equal ["nuke"], charged("ns.send(:nuke, 'x')")
    assert_equal ["hasRootAccess"], charged("ns.__send__(:root_access?, 'x')")
  end

  def test_send_with_a_name_in_a_variable_isnt_charged
    assert_empty scan("m = :hack\nns.public_send(m, 'x')").charges
  end

  def test_methods_on_results_arent_charged
    assert_equal ["getServer"], charged("ns.get_server('x').money_max")
    assert_empty scan("ns.args.first").charges
  end

  def test_other_receivers_arent_charged
    assert_empty charged("'abc'.scan(/b/); farm.hack('x')")
  end

  def test_unknown_names_are_reported
    assert_equal ["ns.hakc"], scan("ns.hakc('x')").unknown
  end

  def test_a_bare_ns_inside_a_library_method_is_charged
    result = scan("require_relative 'lib/ext'\nputs 1.level", "lib/ext.rb" => "class Numeric\n  def level = ns.hacking_level\nend\n")
    assert_equal ["getHackingLevel"], result.charges.map(&:name)
  end

  def test_follows_require_relative
    result = scan("require_relative 'lib/helper'\nHelper.go(ns)", "lib/helper.rb" => "module Helper\n  def self.go(ns) = ns.hack('x')\nend\n")
    assert_equal ["hack"], result.charges.map(&:name)
    assert_equal 2, result.files.size
  end

  def test_breakdown
    assert_equal "1.6 base + hack 0.1", scan("ns.hack('x')").breakdown
  end

  def test_measured_costs_win
    measured = Afterburner::Api.new(FIXTURE_DEFINITIONS, measured: { "hack" => 0.5 })
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, "s.rb"), "ns.hack('x')")
      assert_in_delta 2.1, Afterburner::RamScanner.new(measured).scan(File.join(dir, "s.rb")).ram
    end
  end
end
