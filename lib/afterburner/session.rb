# frozen_string_literal: true

require "async"
require "async/queue"
require "json"
require "logger"
require "stringio"
require "protocol/websocket/message"

module Afterburner
  # The daemon refused to run a script: no such file, or a name it won't load.
  class ScriptNotFound < StandardError; end

  # abort("message") in a script: ends it, showing the message as its error.
  class ScriptAbort < StandardError; end

  # One running Ruby script, tied to one in-game stub over one WebSocket.
  #
  # The protocol, all JSON text frames:
  #
  #   game → daemon  {op: "start", script: "hello.rb", args: [...], pid: 3}
  #   daemon → game  {op: "call", id: 1, path: ["hacknet", "numNodes"], args: [...]}
  #   game → daemon  {op: "result", id: 1, value: ...}  or  {op: "error", id: 1, message: "..."}
  #   daemon → game  {op: "exit"}  or  {op: "fail", message: "..."}
  #
  # Before the script runs, the daemon may ask for the game's RAM costs:
  #
  #   daemon → game  {op: "costs", names: ["hack", "hacknet.numNodes", ...]}
  #   game → daemon  {op: "costs", costs: {"hack": 0.1, ...}}
  #
  # A script makes one call at a time, so the game never sees concurrent ns
  # calls from it. When the game kills the stub, the stub closes the socket and
  # the script is stopped wherever it is.
  class Session
    attr_reader :script, :pid, :args, :ns, :logger

    def initialize(connection, api:, scripts:, log:, costs: nil)
      @connection = connection
      @api = api
      @scripts = scripts
      @log = log
      @costs = costs
      @next_id = 0
      @exit_hooks = []
      @terminal_buffer = +""
    end

    # start: the stub's first message, which the server has already read.
    def run(start)
      return refuse("expected a start message, got #{start['op'].inspect}") unless start["op"] == "start"

      @script = start["script"].to_s
      @pid = start["pid"]
      @args = Codec.decode(start["args"] || []).freeze
      path = @scripts.resolve(@script)
      measure_costs if @costs&.due?
      @ns = NS.new(self, @api)
      @logger = script_logger

      @inbox = Async::Queue.new
      runner = Async { execute(path) }
      reader = Async do
        while (message = receive)
          @inbox.push(message)
        end
        # The stub hung up: the game killed the script, or the game went away.
        @hung_up = true
        runner.stop
      end
      runner.wait
    rescue ScriptNotFound => e
      refuse(e.message)
    ensure
      reader&.stop
    end

    # ns.something(...) from the script: ask the game, wait for its answer.
    def call(path, args)
      raise NetscriptError, "the game has already stopped #{@script}" if @hung_up

      id = (@next_id += 1)
      deliver(op: "call", id:, path:, args: Codec.encode(args))
      reply = @inbox.pop
      raise "reply #{reply['id']} doesn't match call #{id}" unless reply["id"] == id
      raise NetscriptError.from_game(reply["message"]) if reply["op"] == "error"

      Codec.decode(reply["value"])
    end

    # ns.args and ns.pid came with the start message; anything else is asked for.
    def property(path)
      case path
      when ["args"] then @args
      when ["pid"] then @pid
      else call(path, [])
      end
    end

    def at_exit(&block)
      raise ArgumentError, "at_exit needs a block" unless block

      @exit_hooks << block
      block
    end

    # $stdout/$stderr writes from this script's fiber end up here. Whole lines
    # go to the game's terminal; a partial line waits for the rest.
    def terminal_write(text)
      @terminal_buffer << text
      *lines, @terminal_buffer = @terminal_buffer.split("\n", -1)
      call(["tprint"], [lines.join("\n")]) unless lines.empty?
      text.bytesize
    end

    def label = "#{@script} pid #{@pid}"

    private

    def measure_costs
      deliver(op: "costs", names: @api.functions.map(&:qualified_name))
      reply = receive
      @costs.save(reply["costs"]) if reply && reply["op"] == "costs"
    end

    # at_exit blocks run before the game hears the script is done, so they can
    # still use ns. After a kill they run too, but ns calls in them raise.
    def execute(path)
      Fiber[:afterburner_session] = self
      @log.info("[#{label}] started#{" with #{@args.inspect}" unless @args.empty?}")
      failure = run_script(path)
      run_exit_hooks
      flush_terminal
      if failure
        @log.warn("[#{label}] failed: #{failure.lines.first&.chomp}")
        deliver(op: "fail", message: failure)
      else
        @log.info("[#{label}] finished")
        deliver(op: "exit")
      end
    rescue Async::Stop, Async::Cancel
      @log.info("[#{label}] killed in the game")
      @hung_up = true
      run_exit_hooks
      raise
    end

    # Runs the script; returns its failure message, or nil if it ended normally.
    def run_script(path)
      load(path, ScriptContext.build(self))
      nil
    rescue SystemExit
      nil
    rescue Async::Stop, Async::Cancel
      raise
    rescue ScriptAbort => e
      e.message
    rescue Exception => e # rubocop:disable Lint/RescueException -- report SyntaxError and friends too
      describe(e)
    end

    def refuse(message)
      @log.warn("refused: #{message}")
      deliver(op: "fail", message:)
    end

    def flush_terminal
      call(["tprint"], [@terminal_buffer]) unless @terminal_buffer.empty?
      @terminal_buffer = +""
    rescue StandardError
      nil
    end

    def run_exit_hooks
      hooks = @exit_hooks
      @exit_hooks = []
      hooks.reverse_each do |hook|
        hook.call
      rescue Exception => e # rubocop:disable Lint/RescueException
        @log.warn("[#{label}] at_exit hook raised #{e.class}: #{e.message}")
      end
    end

    # "boom (RuntimeError)" plus the backtrace through the script's own files,
    # the way Ruby prints an uncaught exception.
    def describe(error)
      root = "#{@scripts.root}/"
      frames = (error.backtrace || []).filter_map { _1.delete_prefix(root) if _1.start_with?(root) }
      ["#{error.message} (#{error.class})", *frames.map { "\tfrom #{_1}" }].join("\n")
    end

    def deliver(message)
      Protocol::WebSocket::TextMessage.generate(message).send(@connection)
      @connection.flush
    rescue StandardError
      nil # the game already hung up
    end

    def receive
      message = @connection.read or return nil
      JSON.parse(message.to_str)
    rescue StandardError
      nil
    end

    # logger.info "..." writes to the script's log (its tail window), the way
    # a Rails logger writes to the log file while puts writes to the terminal.
    def script_logger
      device = Object.new
      session = self
      device.define_singleton_method(:write) { |text| session.call(["print"], [text.chomp]) }
      device.define_singleton_method(:close) {}
      Logger.new(device, formatter: lambda { |severity, _time, _program, message|
        text = message.is_a?(Exception) ? "#{message.message} (#{message.class})" : message.to_s
        severity == "INFO" ? "#{text}\n" : "#{severity}: #{text}\n"
      })
    end
  end

  # The top-level context a script runs in. Each run gets a fresh module, so
  # constants and methods a script defines don't leak into other scripts.
  module ScriptContext
    def self.build(session)
      ns = session.ns
      logger = session.logger
      Module.new do
        const_set(:ARGV, session.args.dup.freeze)
        const_set(:NetscriptError, Afterburner::NetscriptError)
        define_method(:ns) { ns }
        define_method(:logger) { logger }
        define_method(:at_exit) { |&block| session.at_exit(&block) }
        define_method(:abort) { |message = "aborted"| raise ScriptAbort, message }
        define_method(:exit!) { |*| raise SystemExit }
      end
    end
  end

  # Stands in for $stdout and $stderr in the daemon. Writes from inside a
  # script go to that script's terminal output in the game; writes from
  # anywhere else go to the real stream. So puts, print, p, and warn all work
  # in scripts, including inside classes and gems they call.
  class ScriptOutput
    def initialize(real)
      @real = real
    end

    def write(*strings)
      session = Fiber[:afterburner_session]
      session ? session.terminal_write(strings.join) : @real.write(*strings)
    end

    def puts(*objects) = write(render { _1.puts(*objects) }) && nil
    def print(*objects) = write(render { _1.print(*objects) }) && nil
    def printf(*args) = write(format(*args)) && nil

    def <<(object)
      write(object.to_s)
      self
    end

    def flush
      @real.flush unless Fiber[:afterburner_session]
      self
    end

    def sync = true
    def sync=(_value); end
    def tty? = Fiber[:afterburner_session] ? false : @real.tty?
    alias isatty tty?
    def fileno = @real.fileno
    def external_encoding = @real.external_encoding

    private

    def render
      io = StringIO.new
      yield io
      io.string
    end
  end
end
