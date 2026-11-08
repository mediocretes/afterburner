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
  def serve(files: {}, filesync: nil, definitions: true)
    Dir.mktmpdir do |dir|
      files.each { |name, text| write(dir, name, text) }
      File.write(File.join(dir, "NetscriptDefinitions.d.ts"), FIXTURE_DEFINITIONS) if definitions
      File.write(File.join(dir, "filesync.json"), JSON.generate(filesync)) if filesync
      log = StringIO.new
      config = Afterburner::Config.load(dir, port: PORT)
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

    def initialize(test, files: [])
      @test = test
      @files = files
      @pushed = {}
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
      when "pushFile" then @pushed[params["filename"]] = params["content"] and "OK"
      when "deleteFile" then @deleted << params["filename"] and "OK"
      when "getAllFiles" then @files
      when "calculateRam" then 1.7
      when "getSaveFile" then { "identifier" => "x", "binary" => true, "save" => "\x1F\x8B\x00\xFF".b.unpack("C*").pack("U*") }
      end
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

  # -- The game's Remote API -------------------------------------------------

  def test_connecting_syncs_definitions_files_the_proxy_and_stubs
    files = { "src/hello.rb" => "ns.hack('x')", "dist/plain.js" => "export async function main() {}", "dist/notes.md" => "no" }
    serve(files:, filesync: { scriptsFolder: "dist" }, definitions: false) do |dir, _log|
      game = FakeGame.new(self, files: [{ "filename" => "gone.js", "content" => "#{Afterburner::Stubs::MARKER} from gone.rb." }])
      task = Async { game.run }
      eventually { game.pushed.key?("hello.js") }
      assert_equal FIXTURE_DEFINITIONS, File.read(File.join(dir, "NetscriptDefinitions.d.ts"))
      assert_includes game.pushed.fetch("hello.js"), "ns.ramOverride(1.7);"
      assert_includes game.pushed.fetch("hello.js"), "await serve(ns, \"hello.rb\", #{PORT});"
      assert_equal Afterburner::Stubs.proxy_source, game.pushed.fetch("afterburner/proxy.js")
      assert game.pushed.key?("plain.js")
      refute game.pushed.key?("notes.md")
      eventually { game.deleted.include?("gone.js") }
    ensure
      task&.stop
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

  def test_local_tools_refuse_browsers
    serve do |_dir, log|
      assert_equal "403", get("/save", origin: "https://bitburner-official.github.io").code
      assert_equal "403", get("/ram?file=x.js", origin: "https://evil.example").code
      assert_includes log.string, "refused a connection"
    end
  end

  # -- The console -----------------------------------------------------------

  def test_the_console_relays_calls_to_its_stub
    serve do
      game = FakeGame.new(self)
      game_task = Async { game.run }
      eventually { game.methods.include?("getAllFiles") }
      relayed = []

      console = Async do
        connect("/console?ram=2.5") do |client|
          statuses = []
          until (message = receive(client))["op"] == "attached"
            statuses << message["message"]
          end
          assert_includes statuses.last, "run afterburner/console.js"
          transmit(client, op: "call", id: 1, path: ["getHackingLevel"], args: [])
          relayed << receive(client)
        end
      end

      eventually { game.pushed.key?("afterburner/console.js") }
      assert_includes game.pushed["afterburner/console.js"], "ns.ramOverride(2.5);"
      connect("/script") do |stub|
        transmit(stub, op: "start", script: "@console", args: [], pid: 42)
        call = receive(stub)
        assert_equal ["getHackingLevel"], call["path"]
        transmit(stub, op: "result", id: call["id"], value: 5)
        assert_equal "exit", receive(stub)["op"], "leaving the console ends the stub"
      end
      console.wait
      assert_equal [{ "op" => "result", "id" => 1, "value" => 5 }], relayed
    ensure
      game_task&.stop
    end
  end

  def test_a_console_stub_with_no_console_waiting_is_refused
    serve do
      connect("/script") do |stub|
        transmit(stub, op: "start", script: "@console", args: [], pid: 1)
        assert_equal "fail", receive(stub)["op"]
      end
    end
  end

  def test_the_console_refuses_browsers
    serve do
      assert_raises(StandardError) { connect("/console", origin: "https://bitburner-official.github.io") { nil } }
    end
  end
end
