# frozen_string_literal: true

require_relative "test_helper"
require "async/http/endpoint"
require "async/websocket/client"
require "net/http"

# Runs a real server, with this test playing the game: its Remote API
# connection, the stubs it runs, and the local console.
class ServerTest < Minitest::Test
  include FixtureApi

  PORT = 12_546

  Played = Data.define(:final, :calls, :log)

  # A project directory and a running server for it. Yields [dir, log].
  def serve(files: {}, filesync: nil, definitions: true, **flags)
    Dir.mktmpdir do |dir|
      files.each { |name, text| write(dir, name, text) }
      File.write(File.join(dir, "NetscriptDefinitions.d.ts"), FIXTURE_DEFINITIONS) if definitions
      File.write(File.join(dir, "filesync.json"), JSON.generate(filesync)) if filesync
      log = StringIO.new
      config = Afterburner::Config.load(dir, port: PORT, **flags)
      server = Afterburner::Server.new(config, log: quiet_log(log))
      with_script_output do
        Sync do |task|
          running = task.async { server.run }
          eventually { port_open? }
          yield dir, log
        ensure
          running&.stop
        end
      end
    end
  end

  def write(dir, name, text)
    path = File.join(dir, name)
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, text)
  end

  def eventually(timeout: 5)
    deadline = Time.now + timeout
    until (result = yield)
      raise Minitest::Assertion, "timed out waiting" if Time.now > deadline

      sleep 0.02
    end
    result
  end

  def port_open?
    TCPSocket.new("localhost", PORT).close
    true
  rescue SystemCallError
    false
  end

  def connect(path, origin: nil, &)
    endpoint = Async::HTTP::Endpoint.parse("http://localhost:#{PORT}#{path}")
    Async::WebSocket::Client.connect(endpoint, headers: origin ? [["origin", origin]] : [], &)
  end

  def transmit(connection, message)
    Protocol::WebSocket::TextMessage.generate(message).send(connection)
    connection.flush
  end

  def receive(connection)
    message = connection.read
    message && JSON.parse(message.to_str)
  end

  def get(path, origin: nil)
    request = Net::HTTP::Get.new(path)
    request["origin"] = origin if origin
    Net::HTTP.start("localhost", PORT) { _1.request(request) }
  end

  def with_script_output
    stdout, stderr = $stdout, $stderr
    $stdout = Afterburner::ScriptOutput.new(stdout)
    $stderr = Afterburner::ScriptOutput.new(stderr)
    yield
  ensure
    $stdout, $stderr = stdout, stderr
  end

  # The game's Remote API side: connects to /, answers afterburner's requests.
  class FakeGame
    attr_reader :pushed, :deleted, :methods

    # remote: files on other servers, { "n00dles" => { "name" => "content" } };
    # pushes to them land there, and pushed_to records them.
    attr_reader :remote, :pushed_to

    def initialize(test, files: [], remote: {})
      @test = test
      @files = files
      @remote = remote
      @pushed = {}
      @pushed_to = Hash.new { |h, k| h[k] = {} }
      @deleted = []
      @methods = []
    end

    def run
      @test.connect("/") do |connection|
        while (request = @test.receive(connection))
          @methods << request["method"]
          @test.transmit(connection, jsonrpc: "2.0", id: request["id"], result: answer(request))
        end
      end
    end

    def answer(request)
      params = request["params"] || {}
      case request["method"]
      when "getDefinitionFile" then FIXTURE_DEFINITIONS
      when "pushFile" then push(params) and "OK"
      when "getAllServers"
        [{ "hostname" => "home", "hasAdminRights" => true, "purchasedByPlayer" => true },
         *@remote.keys.map { { "hostname" => _1, "hasAdminRights" => _1 != "unrooted", "purchasedByPlayer" => false } }]
      when "getFileNames" then (@remote[params["server"]] || {}).keys
      when "getFile" then @remote.dig(params["server"], params["filename"])
      when "deleteFile" then @deleted << params["filename"] and "OK"
      when "getAllFiles" then @files
      when "getAllFileMetadata" then @files.map { { "filename" => _1["filename"], "mtime" => _1["mtime"] } }
      when "calculateRam" then 1.7
      when "getSaveFile" then { "identifier" => "x", "binary" => true, "save" => "\x1F\x8B\x00\xFF".b.unpack("C*").pack("U*") }
      end
    end

    def push(params)
      server = params["server"] || "home"
      return @pushed[params["filename"]] = params["content"] if server == "home"

      @remote[server][params["filename"]] = params["content"]
      @pushed_to[server][params["filename"]] = params["content"]
    end
  end

  # Runs a script by playing its stub. answers: "hacknet.numNodes" => value,
  # or an exception to make the call fail.
  def play(source, name: "script.rb", args: [], answers: {}, origin: nil, hang_up_after: nil, files: {}, start: nil)
    played = nil
    serve(files: { "src/#{name}" => source, **files.transform_keys { "src/#{_1}" } }) do |_dir, log|
      calls = []
      final = nil
      connect("/script", origin:) do |connection|
        transmit(connection, start || { op: "start", script: name, args:, pid: 7 })
        while (message = receive(connection))
          case message["op"]
          when "costs" then transmit(connection, op: "costs", costs: message["names"].to_h { [_1, 9.0] })
          when "call"
            calls << [message["path"].join("."), message["args"]]
            break connection.close if hang_up_after && calls.size >= hang_up_after

            transmit(connection, reply(message, answers[message["path"].join(".")]))
          else break final = message
          end
        end
      end
      sleep 0.05 # let the server notice and log
      played = Played.new(final:, calls:, log: log.string)
    end
    played
  end

  def reply(message, answer)
    if answer.is_a?(Exception)
      { op: "error", id: message["id"], message: "RUNTIME ERROR\nscript.js@home (PID - 7)\n\n#{answer.message}" }
    else
      { op: "result", id: message["id"], value: answer }
    end
  end

  # -- Running scripts -------------------------------------------------------

  def test_runs_a_script_and_exits
    played = play("puts \"Hello, \#{ARGV.first}!\"\nns.hack('n00dles')", args: ["world"])
    assert_equal [["tprint", ["Hello, world!"]], ["hack", ["n00dles"]]], played.calls
    assert_equal "exit", played.final["op"]
    assert_includes played.log, "[script.rb pid 7] finished"
  end

  def test_names_options_and_namespaces
    played = play("ns.hack('x', additional_msec: 5)\nns.root_access?('x')\nns.hacknet.num_nodes")
    assert_equal [["hack", ["x", { "additionalMsec" => 5 }]], ["hasRootAccess", ["x"]], ["hacknet.numNodes", []]], played.calls
  end

  def test_results_come_back_as_records
    played = play("puts ns.get_server('n00dles').money_max", answers: { "getServer" => { "moneyMax" => 1_750_000 } })
    assert_equal ["tprint", ["1750000"]], played.calls.last
  end

  def test_p_print_and_warn_reach_the_terminal
    played = play("p [1, :two]\nprint 'a'\nprint \"b\\n\"\nwarn 'careful'")
    assert_equal [["tprint", ["[1, :two]"]], ["tprint", ["ab"]], ["tprint", ["careful"]]], played.calls
  end

  def test_output_from_inside_a_class_reaches_the_terminal
    played = play("class Greeter\n  def go = puts('from a class')\nend\nGreeter.new.go")
    assert_equal [["tprint", ["from a class"]]], played.calls
  end

  def test_logger_writes_to_the_script_log
    played = play("logger.info 'hello'\nlogger.warn 'uh oh'")
    assert_equal [["print", ["hello"]], ["print", ["WARN: uh oh"]]], played.calls
  end

  def test_uncaught_errors_fail_with_a_ruby_backtrace
    played = play("def explode = raise('boom')\nexplode")
    assert_equal "fail", played.final["op"]
    assert_match(/\Aboom \(RuntimeError\)\n\tfrom script\.rb:1/, played.final["message"])
  end

  def test_game_errors_are_rescuable_netscript_errors
    played = play("begin\n  ns.hack('x')\nrescue NetscriptError => e\n  puts \"rescued: \#{e.message}\"\nend",
                  answers: { "hack" => RuntimeError.new("hack: no root on x") })
    assert_equal ["tprint", ["rescued: hack: no root on x"]], played.calls.last
  end

  def test_typos_suggest_the_right_name
    played = play("ns.hakc('x')")
    assert_match(/has no function `hakc'. Did you mean\? hack/, played.final["message"])
  end

  def test_abort_and_exit
    assert_equal({ "op" => "fail", "message" => "giving up" }, play("abort 'giving up'").final)
    assert_equal "exit", play("exit\nns.hack('x')").final["op"]
  end

  def test_rubys_own_sleep_doesnt_block
    assert_equal [["tprint", ["slept"]]], play("sleep 0.01\nputs 'slept'").calls
  end

  def test_at_exit_blocks_can_still_use_ns_when_a_script_ends
    played = play("at_exit { puts 'bye' }\nputs 'hi'")
    assert_equal [["tprint", ["hi"]], ["tprint", ["bye"]]], played.calls
  end

  def test_hanging_up_stops_the_script_and_runs_at_exit
    Dir.mktmpdir do |dir|
      marker = File.join(dir, "ran")
      played = play("at_exit { File.write(#{marker.inspect}, 'yes'); puts 'too late' }\nloop { ns.sleep(10) }", hang_up_after: 2)
      assert_includes played.log, "killed in the game"
      assert_equal "yes", File.read(marker)
      assert_includes played.log, "at_exit hook raised Afterburner::NetscriptError: the game has already stopped script.rb"
    end
  end

  def test_scripts_dont_share_constants_or_methods
    assert_equal [["tprint", ["1"]]], play("LIMIT = 1\ndef helper = 1\nputs LIMIT").calls
    assert_equal [["tprint", ["nil"]], ["tprint", ["false"]]], play("puts defined?(LIMIT).inspect\nputs respond_to?(:helper, true).inspect").calls
  end

  # Scripts are fibers on one thread, and Ruby keeps some load state per
  # thread; two scripts paused mid-run mustn't see each other's definitions.
  def test_scripts_running_at_once_keep_their_own_constants_and_methods
    script = ->(tag) { "LIMIT = '#{tag}'\ndef who = '#{tag}'\n3.times { ns.sleep(1) }\nputs \"\#{LIMIT} \#{who}\"" }
    printed = Hash.new { |h, k| h[k] = [] }
    serve(files: { "src/a.rb" => script.("a"), "src/b.rb" => script.("b") }) do
      %w[a b].map do |name|
        Async do
          connect("/script") do |connection|
            transmit(connection, op: "start", script: "#{name}.rb", args: [], pid: name.ord, ram: 1.6)
            while (message = receive(connection))
              break unless message["op"] == "call" || message["op"] == "costs"
              next transmit(connection, op: "costs", costs: {}) if message["op"] == "costs"

              printed[name] << message["args"].first if message["path"] == ["tprint"]
              sleep 0.01 # let the other script run in between
              transmit(connection, op: "result", id: message["id"], value: nil)
            end
          end
        end
      end.each(&:wait)
    end
    assert_equal({ "a" => ["a a"], "b" => ["b b"] }, printed)
  end

  def test_a_script_started_before_the_definitions_arrive_waits_for_them
    final = nil
    serve(files: { "src/early.rb" => "puts 'ran'" }, definitions: false) do |dir, _log|
      Async do
        sleep 0.6 # the game's Remote API reconnecting after a load
        File.write(File.join(dir, "NetscriptDefinitions.d.ts"), FIXTURE_DEFINITIONS)
      end
      connect("/script") do |connection|
        transmit(connection, op: "start", script: "early.rb", args: [], pid: 1, ram: 1.6)
        while (message = receive(connection))
          case message["op"]
          when "costs" then transmit(connection, op: "costs", costs: {})
          when "call" then transmit(connection, op: "result", id: message["id"], value: nil)
          else break final = message
          end
        end
      end
    end
    assert_equal "exit", final["op"]
  end

  def test_a_script_can_reopen_rubys_classes_and_its_own_classes_stay_its_own
    played = play("class Float\n  def af_test_pct = \"\#{(self * 100).round}%\"\nend\nclass OnlyThisScript; end\nputs 0.25.af_test_pct")
    assert_equal [["tprint", ["25%"]]], played.calls
    refute Object.const_defined?(:OnlyThisScript), "a class the script made leaked to the top level"
  ensure
    Float.send(:remove_method, :af_test_pct) if Float.method_defined?(:af_test_pct)
  end

  # The first time a library loads in afterburner's process, its classes didn't
  # exist when the script's module was built. Reopening one must still reach it.
  def test_a_script_reopens_a_class_from_a_library_it_just_loaded
    library = "class FirstLoadWidget\n  def initialize(size) = @size = size\nend\n"
    script = "require_relative 'lib/widget'\nclass FirstLoadWidget\n  def doubled = @size * 2\nend\n" \
             "puts FirstLoadWidget.new(21).doubled"
    refute Object.const_defined?(:FirstLoadWidget), "the test needs a library loading for the first time"
    played = play(script, files: { "lib/widget.rb" => library })
    assert_equal [["tprint", ["42"]]], played.calls, played.final["message"]
    assert Object.const_get(:FirstLoadWidget).method_defined?(:doubled), "reopened the library's class, not a new one"
  ensure
    Object.send(:remove_const, :FirstLoadWidget) if Object.const_defined?(:FirstLoadWidget)
  end

  def test_a_library_edited_while_nothing_runs_is_fresh_for_the_next_run
    library = "module IdleReloadHelper\n  def self.tag = 'v1'\nend\n"
    printed = []
    serve(files: { "src/uses.rb" => "require_relative 'lib/helper'\nputs IdleReloadHelper.tag", "src/lib/helper.rb" => library }) do |dir, _log|
      run = lambda do
        connect("/script") do |connection|
          transmit(connection, op: "start", script: "uses.rb", args: [], pid: 1, ram: 1.6)
          while (message = receive(connection))
            break unless %w[call costs].include?(message["op"])
            next transmit(connection, op: "costs", costs: {}) if message["op"] == "costs"

            printed << message["args"].first if message["path"] == ["tprint"]
            transmit(connection, op: "result", id: message["id"], value: nil)
          end
        end
      end
      run.call
      write(dir, "src/lib/helper.rb", library.sub("v1", "v2"))
      File.utime(Time.now + 5, Time.now + 5, File.join(dir, "src/lib/helper.rb"))
      sleep 0.8 # a tick or so, with nothing running
      run.call
    end
    assert_equal %w[v1 v2], printed
  end

  # A reload that fails takes the library out of $LOADED_FEATURES, so after the
  # fix the next run's require_relative evaluates it again over the classes the
  # last good load left behind. Ruby's "already initialized constant" warning
  # mustn't reach the script's terminal.
  def test_a_library_fixed_after_a_failed_reload_loads_quietly
    library = "class QuietReloadHelper\n  TABLE = { tag: 'v1' }.freeze\n  def self.tag = TABLE[:tag]\nend\n"
    printed = []
    serve(files: { "src/uses.rb" => "require_relative 'lib/helper'\nputs QuietReloadHelper.tag", "src/lib/helper.rb" => library }) do |dir, log|
      run = lambda do
        connect("/script") do |connection|
          transmit(connection, op: "start", script: "uses.rb", args: [], pid: 1, ram: 1.6)
          while (message = receive(connection))
            break unless %w[call costs].include?(message["op"])
            next transmit(connection, op: "costs", costs: {}) if message["op"] == "costs"

            printed << message["args"].first if message["path"] == ["tprint"]
            transmit(connection, op: "result", id: message["id"], value: nil)
          end
        end
      end
      save = lambda do |text, seconds_ahead|
        write(dir, "src/lib/helper.rb", text)
        File.utime(Time.now + seconds_ahead, Time.now + seconds_ahead, File.join(dir, "src/lib/helper.rb"))
        sleep 0.8 # a tick or so
      end
      run.call
      save.call("#{library}end\n", 5) # a syntax error: the reload fails
      eventually { log.string.include?("reloading lib/helper.rb failed") }
      save.call(library.sub("v1", "v2"), 10)
      run.call
    end
    assert_equal %w[v1 v2], printed
  ensure
    Object.send(:remove_const, :QuietReloadHelper) if Object.const_defined?(:QuietReloadHelper)
  end

  def test_ns_and_logger_work_anywhere_in_a_scripts_code
    library = "class Numeric\n  def af_plus_level = self + ns.hacking_level\nend\n" \
              "class AfTalker\n  def self.go = logger.info('from a class')\nend\n"
    played = play("require_relative 'lib/helpers'\nputs 0.5.af_plus_level\nputs 3.af_plus_level\nAfTalker.go",
                  files: { "lib/helpers.rb" => library }, answers: { "getHackingLevel" => 5 })
    assert_equal [["getHackingLevel", []], ["tprint", ["5.5"]], ["getHackingLevel", []], ["tprint", ["8"]],
                  ["print", ["from a class"]]], played.calls
  ensure
    Numeric.send(:remove_method, :af_plus_level) if Numeric.method_defined?(:af_plus_level)
  end

  def test_ns_outside_a_running_script_says_why
    error = assert_raises(NameError) { Object.new.send(:ns) }
    assert_match(/only available while a Ruby script is running/, error.message)
  end

  def test_refuses_names_outside_the_scripts_or_in_lib
    ["../outside.rb", "/etc/passwd", "lib/helper.rb", "missing.rb"].each do |name|
      played = play("puts 1", files: { "lib/helper.rb" => "" }, start: { op: "start", script: name, args: [], pid: 1 })
      assert_equal "fail", played.final["op"], name
    end
  end

  def test_refuses_other_websites
    assert_raises(StandardError) { play("puts 1", origin: "https://evil.example") }
    assert_equal "exit", play("puts 1", origin: "https://bitburner-official.github.io").final["op"]
  end

  # -- Hot reload ------------------------------------------------------------

  # Runs a looping script with the given RAM claim, swaps in new code once it's
  # going, and plays on until done.(calls, log) or a few seconds pass.
  def play_reload(source, new_source, ram:, files: {}, edit: "src/script.rb", done:, **flags)
    result = nil
    serve(files: { "src/script.rb" => source, **files }, **flags) do |dir, log|
      calls = []
      edited = false
      deadline = Time.now + 5
      connect("/script") do |connection|
        transmit(connection, op: "start", script: "script.rb", args: [], pid: 7, ram:)
        while (message = receive(connection))
          case message["op"]
          when "costs" then transmit(connection, op: "costs", costs: {})
          when "call"
            calls << [message["path"].join("."), message["args"]]
            if !edited && calls.size >= 3
              write(dir, edit, new_source)
              File.utime(Time.now + 5, Time.now + 5, File.join(dir, edit))
              edited = true
            end
            break if done.call(calls, log.string) || Time.now > deadline

            sleep 0.01
            transmit(connection, op: "result", id: message["id"], value: nil)
          else break
          end
        end
      end
      result = [calls, log.string]
    end
    result
  end

  def test_a_changed_script_restarts_in_place
    calls, log = play_reload("loop { ns.print('v1'); ns.sleep(1) }", "loop { ns.print('v2'); ns.sleep(1) }",
                             ram: 1.6, done: ->(calls, _) { calls.include?(["print", ["v2"]]) })
    assert_includes calls, ["print", ["v2"]]
    assert_includes calls, ["print", ["afterburner: reloaded script.rb"]]
    assert_includes log, "[script.rb pid 7] reloaded"
  end

  def test_the_old_codes_at_exit_runs_first_with_ns_working
    calls, = play_reload("at_exit { ns.print('old exit') }\nloop { ns.print('v1'); ns.sleep(1) }",
                         "loop { ns.print('v2'); ns.sleep(1) }", ram: 1.6, done: ->(calls, _) { calls.include?(["print", ["v2"]]) })
    assert_operator calls.index(["print", ["old exit"]]), :<, calls.index(["print", ["afterburner: reloaded script.rb"]])
  end

  def test_a_change_needing_more_ram_than_the_stub_claimed_waits_for_a_rerun
    calls, log = play_reload("loop { ns.print('v1'); ns.sleep(1) }", "loop { ns.hack('x'); ns.sleep(1) }",
                             ram: 1.6, done: ->(_, log) { log.include?("now needs") })
    assert_includes log, "now needs 1.7 GB and its stub claimed 1.6 GB"
    refute_includes calls.map(&:first), "hack"
  end

  def test_what_the_old_code_called_still_counts
    _, log = play_reload("loop { ns.hack('x'); ns.sleep(1) }", "loop { ns.hacking_level; ns.sleep(1) }",
                         ram: 1.7, done: ->(_, log) { log.include?("now needs") })
    assert_includes log, "now needs 1.75 GB"
  end

  def test_changing_a_library_reloads_scripts_that_use_it
    library = "module ReloadTestHelper\n  def self.tag = 'v1'\nend\n"
    calls, log = play_reload("require_relative 'lib/helper'\nloop { ns.print(ReloadTestHelper.tag); ns.sleep(1) }",
                             library.sub("v1", "v2"), ram: 1.6, files: { "src/lib/helper.rb" => library }, edit: "src/lib/helper.rb",
                             done: ->(calls, _) { calls.include?(["print", ["v2"]]) })
    assert_includes calls, ["print", ["v2"]]
    assert_includes log, "reloaded lib/helper.rb"
  end

  def test_reload_can_be_turned_off
    calls, log = play_reload("loop { ns.print('v1'); ns.sleep(1) }", "loop { ns.print('v2'); ns.sleep(1) }",
                             ram: 1.6, reload: false, done: ->(calls, _) { calls.size > 150 })
    refute_includes calls, ["print", ["v2"]]
    refute_includes log, "reloaded"
  end

  # -- The game's Remote API -------------------------------------------------

  def test_connecting_syncs_definitions_files_the_proxy_and_stubs
    files = { "src/hello.rb" => "ns.hack('x')", "dist/plain.js" => "export async function main() {}", "dist/notes.md" => "no" }
    serve(files:, filesync: { scriptsFolder: "dist" }, definitions: false) do |dir, _log|
      game = FakeGame.new(self, files: [{ "filename" => "gone.js", "content" => "#{Afterburner::Stubs::MARKER} from gone.rb." }])
      task = Async { game.run }
      eventually { game.pushed.key?("hello.js") }
      assert_equal FIXTURE_DEFINITIONS, File.read(File.join(dir, "NetscriptDefinitions.d.ts"))
      assert_includes game.pushed.fetch("hello.js"), "ns.ramOverride(1.7);"
      assert_includes game.pushed.fetch("hello.js"), "await serve(ns, \"hello.rb\", #{PORT}, 1.7);"
      assert_equal Afterburner::Stubs.proxy_source, game.pushed.fetch("afterburner/proxy.js")
      assert game.pushed.key?("plain.js")
      refute game.pushed.key?("notes.md")
      eventually { game.deleted.include?("gone.js") }
    ensure
      task&.stop
    end
  end

  def test_connecting_updates_proxy_copies_on_other_servers
    serve(files: { "src/hello.rb" => "ns.hack('x')" }) do |_dir, log|
      current = Afterburner::Stubs.proxy_source
      game = FakeGame.new(self, remote: {
                            "n00dles" => { "afterburner/proxy.js" => "// an old proxy", "hgw1.js" => "x" },
                            "foodnstuff" => { "afterburner/proxy.js" => current },
                            "joesguns" => { "notes.txt" => "no proxy here" },
                            "unrooted" => { "afterburner/proxy.js" => "// old, but not on a server you have root on" },
                          })
      task = Async { game.run }
      eventually { log.string.include?("updated afterburner/proxy.js on 1 other server") }
      assert_equal({ "n00dles" => { "afterburner/proxy.js" => current } }, game.pushed_to.to_h)
    ensure
      task&.stop
    end
  end

  def test_a_game_without_get_all_servers_still_syncs
    serve(files: { "src/hello.rb" => "ns.hack('x')" }) do |_dir, log|
      game = FakeGame.new(self)
      game.define_singleton_method(:answer) { |request| request["method"] == "getAllServers" ? nil : super(request) }
      task = Async { game.run }
      eventually { game.pushed.key?("hello.js") }
      sleep 0.2
      refute_match(/couldn't update|failed/, log.string)
    ensure
      task&.stop
    end
  end

  # Plays a stub's side of one run: start, answer calls, return the last message.
  def run_stub(start)
    connect("/script") do |connection|
      transmit(connection, start)
      while (message = receive(connection))
        next transmit(connection, op: "costs", costs: {}) if message["op"] == "costs"
        return message unless message["op"] == "call"

        transmit(connection, op: "result", id: message["id"], value: nil)
      end
    end
  end

  def test_scripts_resumed_after_a_restart_run_again_and_are_summed_up_in_one_line
    serve(files: { "src/farm.rb" => "ns.hack(ARGV.first)" }) do |_dir, log|
      finals = [7, 8].map { |pid| run_stub(op: "start", script: "farm.rb", args: ["n00dles"], pid:, ram: 1.7, resumed: true) }
      assert_equal %w[exit exit], finals.map { _1["op"] }
      eventually(timeout: 6) { log.string.include?("2 Ruby scripts reconnected and started again from the top") }
      refute_includes log.string, "started with", "a resume isn't logged as a fresh start"
    end
  end

  def test_a_resumed_script_that_now_needs_more_ram_ends_quietly
    serve(files: { "src/farm.rb" => "ns.hack(ARGV.first)\nns.get_server(ARGV.first)" }) do |_dir, log|
      final = run_stub(op: "start", script: "farm.rb", args: ["n00dles"], pid: 7, ram: 1.7, resumed: true)
      assert_equal "exit", final["op"], "ends without an error dialog: #{final["message"]}"
      assert_match(/now needs [\d.]+ GB, more than this process claimed \(1\.7 GB\)\. Run it again/, final["message"])
      eventually { log.string.include?("[farm.rb pid 7] not resumed") }
    end
  end

  def test_a_fresh_start_that_needs_more_than_its_claim_is_not_refused
    serve(files: { "src/farm.rb" => "ns.hack(ARGV.first)\nns.get_server(ARGV.first)" }) do |_dir, _log|
      final = run_stub(op: "start", script: "farm.rb", args: ["n00dles"], pid: 7, ram: 1.7)
      assert_equal "exit", final["op"]
      assert_nil final["message"]
    end
  end

  def test_changes_reach_the_game_while_connected
    files = { "src/hello.rb" => "ns.hack('x')", "dist/plain.js" => "one" }
    serve(files:, filesync: { scriptsFolder: "dist", allowDeletingFiles: true }) do |dir, _log|
      game = FakeGame.new(self)
      task = Async { game.run }
      eventually { game.pushed.key?("hello.js") && game.pushed.key?("plain.js") }

      write(dir, "dist/plain.js", "two")
      File.utime(Time.now + 5, Time.now + 5, File.join(dir, "dist/plain.js"))
      eventually { game.pushed["plain.js"] == "two" }

      write(dir, "src/new.rb", "ns.hacking_level")
      eventually { game.pushed.key?("new.js") }
      File.delete(File.join(dir, "src/new.rb"))
      eventually { game.deleted.include?("new.js") }

      File.delete(File.join(dir, "dist/plain.js"))
      eventually { game.deleted.include?("plain.js") }
    ensure
      task&.stop
    end
  end

  def test_save_and_ram_ask_the_game
    serve(files: { "src/hello.rb" => "ns.hack('x')" }) do
      assert_equal "503", get("/save").code
      game = FakeGame.new(self)
      task = Async { game.run }
      eventually { game.methods.include?("getAllFiles") }

      save = get("/save")
      assert_equal "\x1F\x8B\x00\xFF".b, save.body.b
      assert_match(/\AbitburnerSave_\d+\.json\.gz\z/, save["x-afterburner-filename"])
      assert_equal "1.7", get("/ram?file=hello.js").body
    ensure
      task&.stop
    end
  end

  def test_scripts_are_copied_into_the_save_and_served_back_for_restore
    saved_elsewhere = { "filename" => "afterburner/src/other.rb.txt", "content" => "puts 'from the other machine'", "mtime" => 1 }
    serve(files: { "src/hello.rb" => "puts 'hi'", "src/lib/util.rb" => "X = 1" }) do |dir, log|
      game = FakeGame.new(self, files: [saved_elsewhere])
      task = Async { game.run }
      eventually { game.pushed.key?("afterburner/src/hello.rb.txt") }
      assert_equal "puts 'hi'", game.pushed["afterburner/src/hello.rb.txt"]
      assert_equal "X = 1", game.pushed["afterburner/src/lib/util.rb.txt"]
      eventually { log.string.include?("the save holds 1 Ruby file that src/ doesn't (other.rb)") }

      sources = JSON.parse(get("/sources").body)
      assert_equal [{ "name" => "other.rb", "content" => "puts 'from the other machine'", "mtime" => 1 }], sources

      write(dir, "src/hello.rb", "puts 'hello again'")
      File.utime(Time.now + 5, Time.now + 5, File.join(dir, "src/hello.rb"))
      eventually { game.pushed["afterburner/src/hello.rb.txt"] == "puts 'hello again'" }
      File.delete(File.join(dir, "src/lib/util.rb"))
      eventually { game.deleted.include?("afterburner/src/lib/util.rb.txt") }
      refute_includes game.deleted, "afterburner/src/other.rb.txt", "copies from elsewhere stay"
    ensure
      task&.stop
    end
  end

  def test_local_tools_refuse_browsers
    serve do |_dir, log|
      assert_equal "403", get("/save", origin: "https://bitburner-official.github.io").code
      assert_equal "403", get("/ram?file=x.js", origin: "https://evil.example").code
      assert_includes log.string, "refused a connection"
    end
  end

  # -- The console -----------------------------------------------------------

  # Plays the console script's first message; the block gets its socket.
  def console_script(pid: 42, ram: 4.0, resumed: false, &)
    connect("/script") do |stub|
      transmit(stub, op: "start", script: "@console", args: [], pid:, ram:, resumed:)
      yield stub
    end
  end

  # Receives an attach and echoes it, as the console script does.
  def echo_attach(stub)
    message = receive(stub)
    assert_equal "attach", message["op"]
    transmit(stub, op: "attached", session: message["session"])
    message
  end

  # Reads a console's messages up to "attached"; returns [statuses, attached].
  def until_attached(client)
    statuses = []
    until (message = receive(client))["op"] == "attached"
      statuses << message["message"]
    end
    [statuses, message]
  end

  def with_game
    game = FakeGame.new(self)
    game_task = Async { game.run }
    eventually { game.methods.include?("getAllFiles") }
    yield game
  ensure
    game_task&.stop
  end

  def test_the_console_relays_calls_to_its_stub
    serve do
      with_game do |game|
        relayed = []
        console = Async do
          connect("/console?ram=2.5") do |client|
            statuses, = until_attached(client)
            assert_includes statuses.last, "run afterburner/console.js"
            transmit(client, op: "call", id: 1, path: ["getHackingLevel"], args: [])
            relayed << receive(client)
          end
        end
        eventually { game.pushed.key?("afterburner/console.js") }
        assert_includes game.pushed["afterburner/console.js"], "ns.ramOverride(2.5);"
        console_script do |stub|
          echo_attach(stub)
          call = receive(stub)
          assert_equal ["getHackingLevel"], call["path"]
          transmit(stub, op: "result", id: call["id"], value: 5)
          console.wait
          sleep 0.1
          refute stub_ended?(stub), "leaving the console parks the script rather than ending it"
        end
        assert_equal [{ "op" => "result", "id" => 1, "value" => 5 }], relayed
      end
    end
  end

  # True if afterburner has told the stub to exit (or closed it) within a moment.
  def stub_ended?(stub)
    message = Async::Task.current.with_timeout(0.2) { receive(stub) }
    message.nil? || message["op"] == "exit"
  rescue Async::TimeoutError
    false
  end

  def test_the_next_console_attaches_to_the_parked_script_without_a_run
    serve do |_dir, log|
      with_game do |game|
        console_script(pid: 9, ram: 25.6) do |stub|
          eventually { log.string.include?("console script pid 9 is running") }
          2.times do |n|
            console = Async do
              connect("/console") do |client|
                statuses, attached = until_attached(client)
                refute statuses.any? { _1.to_s.include?("run afterburner/console.js") }, "no run needed (console #{n + 1})"
                assert_equal 9, attached["pid"]
              end
            end
            echo_attach(stub)
            console.wait
            eventually { log.string.scan("stays running for the next one").size == n + 1 }
          end
          refute game.pushed.key?("afterburner/console.js"), "nothing to push: the script is already running"
        end
      end
    end
  end

  def test_an_answer_the_last_console_left_in_flight_is_dropped
    serve do
      with_game do
        console_script do |stub|
          first = Async do
            connect("/console") do |client|
              until_attached(client)
              transmit(client, op: "call", id: 1, path: ["getHackingLevel"], args: [])
            end # leaves before the answer
          end
          echo_attach(stub)
          old_call = receive(stub)
          first.wait
          answered = []
          second = Async do
            connect("/console") do |client|
              until_attached(client)
              transmit(client, op: "call", id: 1, path: ["getHackingLevel"], args: [])
              answered << receive(client)
            end
          end
          attach = receive(stub)
          assert_equal "attach", attach["op"]
          transmit(stub, op: "result", id: old_call["id"], value: 111) # the old call finishing late
          transmit(stub, op: "attached", session: attach["session"])
          new_call = receive(stub)
          transmit(stub, op: "result", id: new_call["id"], value: 222)
          second.wait
          assert_equal [222], answered.map { _1["value"] }
        end
      end
    end
  end

  def test_an_attach_behind_a_call_in_progress_says_so
    serve do
      with_game do
        console_script do |stub|
          statuses = nil
          console = Async { connect("/console") { |client| statuses, = until_attached(client) } }
          attach = receive(stub)
          sleep(Afterburner::Server::BUSY_NOTICE + 0.3) # still finishing a long call
          transmit(stub, op: "attached", session: attach["session"])
          console.wait
          assert(statuses.any? { _1.include?("finishing a call") })
        end
      end
    end
  end

  def test_a_second_console_script_ends_quietly
    serve do |_dir, log|
      console_script(pid: 1) do
        eventually { log.string.include?("console script pid 1 is running") }
        console_script(pid: 2) do |second|
          message = receive(second)
          assert_equal "exit", message["op"], "an exit, not a failure with an error dialog"
          assert_match(/pid 1 is already running/, message["message"])
        end
      end
    end
  end

  def test_a_parked_script_that_dies_isnt_attached_to
    serve do |_dir, log|
      with_game do |game|
        console_script(pid: 3) { eventually { log.string.include?("console script pid 3 is running") } }
        eventually { log.string.include?("console script pid 3 ended") }
        connect("/console") do |client|
          message = receive(client)
          assert_includes message["message"], "run afterburner/console.js"
        end
        assert game.pushed.key?("afterburner/console.js")
      end
    end
  end

  def test_end_console_ends_the_script_and_lets_the_console_know
    serve do |_dir, log|
      with_game do
        console_script(pid: 5) do |stub|
          console = Async do
            connect("/console") do |client|
              until_attached(client)
              transmit(client, op: "end_console")
              detached = receive(client)
              assert_equal "detached", detached["op"]
            end
          end
          echo_attach(stub)
          exit = receive(stub)
          assert_equal "exit", exit["op"]
          stub.close
          console.wait
        end
        eventually { log.string.include?("console script pid 5 ended") }
      end
    end
  end

  def test_ram_for_a_script_already_running_is_explained
    serve do |_dir, log|
      with_game do
        console_script(pid: 6, ram: 25.6) do |stub|
          eventually { log.string.include?("console script pid 6 is running") }
          attached = nil
          console = Async { connect("/console?ram=8") { |client| _, attached = until_attached(client) } }
          echo_attach(stub)
          console.wait
          assert_match(/--ram applies when a console script starts; this one already holds 25.6 GB/, attached["note"])
        end
      end
    end
  end

  def test_a_console_rejoining_waits_for_the_script_to_reconnect
    serve do
      with_game do |game|
        statuses = attached = nil
        console = Async { connect("/console?rejoin=1") { |client| statuses, attached = until_attached(client) } }
        sleep 0.3
        console_script(pid: 8, resumed: true) do |stub|
          echo_attach(stub)
          console.wait
        end
        assert_equal ["Waiting for the console script to reconnect..."], statuses
        assert_equal 8, attached["pid"]
        refute game.pushed.key?("afterburner/console.js")
      end
    end
  end

  # The console client itself: a call made while the console script is gone
  # waits, the console reattaches to the next one, and the call goes through.
  def test_the_console_client_reattaches_when_the_script_comes_back
    serve do |dir, _log|
      with_game do
        out = StringIO.new
        console = Afterburner::Console.new(port: PORT, ram: nil, definitions: File.join(dir, "NetscriptDefinitions.d.ts"), out:)
        connection = Thread.new { console.send(:stay_connected) }
        first = Thread.new { console.call(["getHackingLevel"], []) }
        console_script(pid: 11) do |stub|
          echo_attach(stub)
          call = receive(stub)
          transmit(stub, op: "result", id: call["id"], value: 1)
          eventually { !first.alive? }
        end # the script stops in the game
        eventually { out.string.include?("The console script stopped in the game.") }
        # A call made at the moment the script stopped says it may not have
        # happened; this one comes after, so it waits for the next script.
        second = Thread.new { console.call(["getHackingLevel"], []) }
        console_script(pid: 12, resumed: true) do |stub|
          echo_attach(stub)
          call = receive(stub)
          transmit(stub, op: "result", id: call["id"], value: 2)
          eventually(timeout: 10) { !second.alive? }
        end
        assert_equal [1, 2], [first.value, second.value]
        assert_includes out.string, "The console script stopped in the game."
        assert_includes out.string, "Reattached to the console script (pid 12)."
      ensure
        console&.send(:leave)
        connection&.join(3)
      end
    end
  end

  # Opens a console at path, runs its stub claiming granted GB, and leaves.
  # Returns the console's status messages, its "attached" message, and the
  # stub the game was sent.
  def attach_console(path, granted:)
    statuses = attached = stub_source = nil
    serve do
      with_game do |game|
        console = Async { connect(path) { |client| statuses, attached = until_attached(client) } }
        eventually { game.pushed.key?("afterburner/console.js") }
        stub_source = game.pushed["afterburner/console.js"]
        console_script(pid: 7, ram: granted) do |stub|
          echo_attach(stub)
          console.wait
        end
      end
    end
    [statuses, attached, stub_source]
  end

  def test_the_console_claims_80_percent_of_free_ram_by_default
    statuses, attached, stub_source = attach_console("/console", granted: 25.6)
    assert_includes statuses.last, "80% of the free RAM where it runs"
    assert_includes stub_source, "* 0.8 * 100) / 100"
    assert_equal 25.6, attached["ram"], "the console hears what the game granted"
  end

  def test_the_console_takes_a_percentage
    statuses, _attached, stub_source = attach_console("/console?ram=50%25", granted: 16)
    assert_includes statuses.last, "50% of the free RAM"
    assert_includes stub_source, "* 0.5 * 100) / 100"
  end

  def test_the_console_takes_gb
    statuses, attached, stub_source = attach_console("/console?ram=8", granted: 8.0)
    assert_includes statuses.last, "it claims 8 GB"
    assert_includes stub_source, "ns.ramOverride(8.0);"
    assert_equal 8.0, attached["ram"]
  end

  def test_the_console_refuses_a_ram_it_cant_read
    serve do
      connect("/console?ram=lots") do |client|
        message = receive(client)
        assert_equal "error", message["op"]
        assert_match(/GB.*percentage/, message["message"])
      end
    end
  end

  def test_leaving_a_waiting_console_frees_it_for_the_next
    serve do |_dir, log|
      connect("/console?ram=2") { |client| receive(client) } # leave while it waits for the game
      sleep 0.1
      connect("/console?ram=2") do |client|
        refute_equal "error", receive(client)["op"], "the first console should no longer count as open"
      end
      refute_includes log.string, "Another console"
    end
  end

  def test_the_console_refuses_browsers
    serve do
      assert_raises(StandardError) { connect("/console", origin: "https://bitburner-official.github.io") { nil } }
    end
  end
end
