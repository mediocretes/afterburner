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

  def test_main_script_and_program_file_cost_nothing
    result = scan("if main_script?\n  puts program_file\nend\nputs main_script?(__FILE__)")
    assert_in_delta 1.6, result.ram
    assert_empty result.charges
    assert_empty result.unknown
    assert_nil result.fallback
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
      helper(ns)
      Farm.new(ns).go
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

  # -- Only reachable code is charged -------------------------------------

  # Shaped like a real Server class, using functions the fixture API has.
  SERVER_LIBRARY = <<~RUBY
    class Server
      OPENERS = {
        "BruteSSH.exe" => ->(host) { ns.hack(host) },
        "FTPCrack.exe" => lambda { |host| ns.root_access?(host) },
      }.freeze

      def initialize(hostname) = @hostname = hostname
      def ratio = ns.server_max_money(@hostname)
      def root! = OPENERS.each_value { _1.(@hostname) } && ns.nuke(@hostname)
      def self.walk = ns.hacking_level
    end
  RUBY

  def test_a_library_method_the_script_never_calls_isnt_charged
    result = scan("require_relative 'lib/server'\nputs Server.new('x').ratio", "lib/server.rb" => SERVER_LIBRARY)
    assert_equal %w[getServerMaxMoney], result.charges.map(&:name)
    assert_equal %w[getHackingLevel hack hasRootAccess nuke], result.skipped.map(&:name)
    assert_nil result.fallback
  end

  def test_calling_a_method_reaches_what_it_calls_and_the_constants_it_reads
    result = scan("require_relative 'lib/server'\nServer.new('x').root!\nServer.walk", "lib/server.rb" => SERVER_LIBRARY)
    assert_equal %w[getHackingLevel hack hasRootAccess nuke], result.charges.map(&:name)
    assert_equal %w[getServerMaxMoney], result.skipped.map(&:name)
  end

  def test_load_time_code_in_a_library_is_always_charged
    library = "class Server\n  LEVEL = ns.hacking_level\n  def unused = ns.hack('x')\nend\n"
    result = scan("require_relative 'lib/server'", "lib/server.rb" => library)
    assert_equal %w[getHackingLevel], result.charges.map(&:name)
  end

  def test_a_name_reaches_every_method_with_that_name
    source = "class A; def go = ns.hack('x'); end\nclass B; def go = ns.nuke('x'); end\nthing.go"
    assert_equal %w[hack nuke], charged(source)
  end

  def test_names_passed_as_literals_count_as_calls
    source = <<~RUBY
      class Farm
        def a = ns.hack("x")
        def b = ns.nuke("x")
        def c = ns.hacking_level
        def d = ns.root_access?("x")
      end
      farm = Farm.new
      farm.public_send(:a)
      [farm].map(&:b)
      farm.method("c")
      farm.respond_to?(:d)
    RUBY
    assert_equal %w[getHackingLevel hack hasRootAccess nuke], charged(source)
  end

  def test_methods_ruby_calls_itself_are_charged
    source = <<~RUBY
      class Target
        def to_s = ns.hacking_level.to_s
        def <=>(other) = ns.server_max_money("x") <=> 0
        def unused = ns.nuke("x")
      end
      puts "level \#{Target.new}"
    RUBY
    assert_equal %w[getHackingLevel getServerMaxMoney], charged(source)
  end

  def test_compound_operators_aliases_and_define_method
    source = <<~RUBY
      class Money
        def +(other) = ns.hacking_level
        def old = ns.nuke("x")
        alias new_name old
        define_method(:made) { ns.hack("x") }
        define_method(:unmade) { ns.root_access?("x") }
      end
      total = Money.new
      total += 1
      total.new_name
      total.made
    RUBY
    assert_equal %w[getHackingLevel hack nuke], charged(source)
  end

  def test_dynamic_dispatch_charges_everything_and_says_why
    source = "class Farm\n  def a = ns.hack('x')\nend\nname = gets\nFarm.new.public_send(name)"
    result = scan(source)
    assert_equal %w[hack], result.charges.map(&:name)
    assert_match(/public_send with a name the scan can't read \(script\.rb:5\)/, result.fallback)
  end

  def test_eval_of_a_string_charges_everything
    result = scan("class Farm\n  def a = ns.hack('x')\nend\neval(gets)")
    assert_equal %w[hack], result.charges.map(&:name)
    assert_match(/eval of a string/, result.fallback)
  end

  def test_dynamic_dispatch_in_code_that_never_runs_doesnt_count
    source = "class Farm\n  def a = ns.hack('x')\n  def b(name) = public_send(name)\nend\nns.nuke('x')"
    result = scan(source)
    assert_equal %w[nuke], result.charges.map(&:name)
    assert_nil result.fallback
  end

  def test_a_name_in_a_variable_sent_to_ns_is_still_just_not_charged
    result = scan("m = :hack\nns.public_send(m, 'x')")
    assert_nil result.fallback
    assert_empty result.charges
  end

  # -- Cases an adversarial review found; each call runs at runtime ------------

  def test_attribute_writes_call_the_reader_and_setter
    source = <<~RUBY
      class Job
        def threads = 1
        def threads=(n) = ns.print("threads now \#{n}")
        def best = ns.hacking_level
        def best=(v) = v
        def host=(h) = ns.nuke(h)
      end
      job = Job.new
      job.threads += 1
      job.best ||= 0
      j = job
      j.host, _ = "n00dles", 1
    RUBY
    assert_equal %w[getHackingLevel nuke print], charged(source)
  end

  def test_index_writes_call_brackets
    source = <<~RUBY
      class Cache
        def [](host) = ns.get_server(host)
        def []=(host, value) = value
      end
      cache = Cache.new
      cache["n00dles"] ||= 0
    RUBY
    assert_equal %w[getServer], charged(source)
  end

  def test_block_arguments_the_scan_cant_follow_charge_everything
    library = "class Farm\n  def go = ns.hack('x')\nend\n"
    {
      "STRATEGY = { early: :go }.freeze\n[Farm.new].each(&STRATEGY[:early])" => /block argument/,
      "step = 'go'.to_sym\n[Farm.new].map(&step)" => /block argument/,
      "p = :go\np.to_proc.call(Farm.new)" => /to_proc/,
      "op = :+\n[1, 2].inject(op)" => /inject/,
      "Farm.new.singleton_method(gets)" => /singleton_method/,
      "Farm.alias_method(:run, gets.to_sym)" => /alias_method/,
    }.each do |script, why|
      result = scan("require_relative 'lib/farm'\n#{script}", "lib/farm.rb" => library)
      assert_equal %w[hack], result.charges.map(&:name), script
      assert_match why, result.fallback, script
    end
  end

  def test_block_arguments_the_scan_can_follow_dont_fall_back
    source = <<~RUBY
      class Farm
        def go = ns.hack("x")
        def each_target(&block) = %w[a].each(&block)
        def unused = ns.nuke("x")
      end
      rooted = ->(host) { ns.root_access?(host) }
      %w[a].select(&rooted)
      %w[a].each(&method(:puts))
      [Farm.new].each(&:go)
      Farm.new.each_target { }
      :go.to_proc
    RUBY
    result = scan(source)
    assert_nil result.fallback
    assert_equal %w[hack hasRootAccess], result.charges.map(&:name)
  end

  def test_exceptions_messages_count_as_called
    assert_equal %w[getHackingLevel], charged("class TargetError < StandardError\n  def message = ns.hacking_level.to_s\nend\nraise TargetError")
  end

  def test_lambdas_that_run_while_a_constant_is_built_are_charged
    {
      "LEVEL = -> { ns.hacking_level }.call" => %w[getHackingLevel],
      "DONE = proc { ns.tprint('starting') }.call" => %w[tprint],
      "ROOTED = %w[a].select(&->(h) { ns.root_access?(h) })" => %w[hasRootAccess],
      "class Command\n  def initialize(f) = f\nend\nHACK = Command.new(->(t) { ns.hack(t) })" => %w[hack],
      "OPEN = DEFAULT_OPEN = -> { ns.nuke('x') }\nOPEN.call" => %w[nuke],
    }.each { |source, expected| assert_equal expected, charged(source), source }
  end

  def test_lambdas_kept_as_data_in_a_constant_still_wait_for_it
    source = "OPENERS = { 'a' => ->(h) { ns.hack(h) }, 'b' => [proc { ns.nuke('x') }] }.freeze\nputs 1"
    result = scan(source)
    assert_empty result.charges
    assert_equal %w[hack nuke], result.skipped.map(&:name)
  end

  def test_const_get_with_a_path
    library = "module Openers\n  ALL = { 'x' => -> { ns.nuke('x') } }\nend\n"
    assert_equal %w[nuke], charged("require_relative 'lib/openers'\nObject.const_get('Openers::ALL').each_value(&:call)",
                                   "lib/openers.rb" => library)
  end

  def test_dispatch_by_a_name_that_dispatches_again_charges_everything
    library = "class Farm\n  def go = ns.hack('x')\nend\n"
    ["Farm.new.send(:public_send, gets)", "Farm.new.method(:public_send).call(gets)",
     "Kernel.instance_method(:public_send).bind_call(Farm.new, gets)", "send(:eval, gets)",
     "RubyVM::InstructionSequence.compile(gets).eval"].each do |script|
      result = scan("require_relative 'lib/farm'\n#{script}", "lib/farm.rb" => library)
      assert_equal %w[hack], result.charges.map(&:name), script
      refute_nil result.fallback, script
    end
  end

  def test_names_ruby_and_the_standard_library_call
    {
      "class Servers < Hash\n  def default(host) = ns.get_server(host)\nend\nServers.new['n00dles']" => %w[getServer],
      "class GameLog\n  def write(text) = ns.print(text)\nend\nrequire 'logger'\nLogger.new(GameLog.new).info('x')" => %w[print],
      "def `(cmd) = ns.tprint(cmd)\n`hello`" => %w[tprint],
    }.each { |source, expected| assert_equal expected, charged(source), source }
  end

  def test_sends_to_ns_with_a_string_or_mid_chain_are_charged
    assert_equal %w[hack], charged("ns.public_send('hack', 'x')")
    assert_equal %w[hacknet.numNodes], charged("ns.send(:hacknet).num_nodes")
    assert_equal %w[hacknet.numNodes], charged("ns.hacknet.public_send('num_nodes')")
  end

  def test_measured_costs_win
    measured = Afterburner::Api.new(FIXTURE_DEFINITIONS, measured: { "hack" => 0.5 })
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, "s.rb"), "ns.hack('x')")
      assert_in_delta 2.1, Afterburner::RamScanner.new(measured).scan(File.join(dir, "s.rb")).ram
    end
  end
end
