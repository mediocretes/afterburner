# frozen_string_literal: true

require "async"
require "async/queue"
require "json"
require "logger"
require "set"
require "protocol/websocket/message"

module Afterburner
  # The server refused to run a script: no such file, or a name it won't load.
  class ScriptNotFound < StandardError; end

  # abort("message") in a script: ends it, showing the message as its error.
  class ScriptAbort < StandardError; end

  # What Async raises in a task it's stopping. Named by whichever constants
  # this version of async has, so a rename there can't break a rescue here.
  STOPPED = %i[Stop Cancel].filter_map { Async.const_get(_1) if Async.const_defined?(_1) }.freeze

  # One running Ruby script, tied to one in-game stub over one WebSocket.
  #
  # The protocol, all JSON text frames:
  #
  #   stub → server  {op: "start", script: "hello.rb", args: [...], pid: 3, ram: 1.7}
  #   server → stub  {op: "call", id: 1, path: ["hacknet", "numNodes"], args: [...]}
  #   stub → server  {op: "result", id: 1, value: ...}  or  {op: "error", id: 1, message: "..."}
  #   server → stub  {op: "exit"}  or  {op: "fail", message: "..."}
  #
  # Before the script runs, the server may ask for the game's RAM costs:
  #
  #   server → stub  {op: "costs", names: ["hack", "hacknet.numNodes", ...]}
  #   stub → server  {op: "costs", costs: {"hack": 0.1, ...}}
  #
  # A script makes one call at a time, so the game never sees concurrent ns
  # calls from it. When the game kills the stub, the stub closes the socket and
  # the script is stopped wherever it is.
  #
  # Hot reload: when one of the script's files changes, #reload restarts it
  # inside the same stub (same pid, same arguments), provided the stub's RAM
  # claim covers everything the script has called so far plus the new code.
  # The game charges each distinct function once per process, so functions
  # the old code called still count.
  class Session
    attr_reader :script, :pid, :args, :ns, :logger, :files, :api

    # The .rb file the game ran, as a real path (main_script? and program_file).
    def program_file = @path

    def initialize(connection, api:, scripts:, log:, costs: nil, ram_api: nil)
      @connection = connection
      @api = api
      @scripts = scripts
      @log = log
      @costs = costs
      @ram_api = ram_api || api
      @next_id = 0
      @exit_hooks = []
      @terminal_buffer = +""
      @called = Set.new
      @files = []
      @runs = 0
    end

    # start: the stub's first message, which the server has already read.
    def run(start)
      return refuse("expected a start message, got #{start['op'].inspect}") unless start["op"] == "start"

      @script = start["script"].to_s
      @pid = start["pid"]
      @args = Codec.decode(start["args"] || []).freeze
      @claim = start["ram"]
      @resumed = start["resumed"] == true
      @path = @scripts.resolve(@script)
      scan = RamScanner.new(@ram_api).scan(@path)
      @files = scan.files
      return outgrown(scan.ram) if @resumed && @claim && scan.ram > @claim + 1e-9
      measure_costs if @costs&.due?
      @ns = NS.new(self, @api)
      @logger = script_logger

      @inbox = Async::Queue.new
      reader = Async do
        while (message = receive)
          @inbox.push(message)
        end
        # The stub hung up: the game killed the script, or the game went away.
        @hung_up = true
        @runner&.stop
      end
      loop do
        @reloading = @restart = false
        @runner = Async { execute }
        @runner.wait
        break unless @restart && !@hung_up

        @runs += 1
      end
    rescue ScriptNotFound => e
      refuse(e.message)
    ensure
      reader&.stop
    end

    # One of this script's files changed. Restarts it in place if the stub's
    # RAM claim still covers it; otherwise says why not and leaves it running.
    def reload(ram_api)
      return if @runner.nil? || !@runner.alive? || @hung_up || @reloading

      scan = RamScanner.new(ram_api).scan(@path)
      needed = ram_api.ram_for(@called.to_a + scan.charges.map(&:name))
      if @claim.nil? || needed > @claim + 1e-9
        @log.warn("[#{label}] changed, but now needs #{needed} GB and its stub claimed #{@claim || '?'} GB; " \
                  "run it again to pick up the change")
        return
      end
      @files = scan.files
      @reloading = true
      @runner.stop
    end

    # ns.something(...) from the script: ask the game, wait for its answer.
    def call(path, args)
      raise NetscriptError, "the game has already stopped #{@script}" if @hung_up

      id = (@next_id += 1)
      @called << path.join(".")
      deliver(op: "call", id:, path:, args: Codec.encode(args))
      reply = nil
      # Answers to calls a reload interrupted arrive late; they're dropped here.
      reply = @inbox.pop until reply && reply["id"] == id
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
    # still use ns. After a kill they run too, but ns calls in them raise. A
    # reload runs the old code's blocks at the start of the new run, once ns
    # works again.
    def execute
      Fiber[:afterburner_session] = self
      if @runs.zero? && @resumed
        # The server sums these up in one line; one per script would flood the log.
        @log.debug("[#{label}] resumed")
      elsif @runs.zero?
        @log.info("[#{label}] started#{" with #{@args.inspect}" unless @args.empty?}")
      else
        run_exit_hooks
        @log.info("[#{label}] reloaded")
        call(["print"], ["afterburner: reloaded #{@script}"])
      end
      failure = run_script
      run_exit_hooks
      flush_terminal
      if failure
        @log.warn("[#{label}] failed: #{failure.lines.first&.chomp}")
        deliver(op: "fail", message: failure)
      else
        @log.info("[#{label}] finished")
        deliver(op: "exit")
      end
    rescue *STOPPED
      return @restart = true if @reloading && !@hung_up # the next run takes over

      @log.info("[#{label}] killed in the game")
      @hung_up = true
      run_exit_hooks
      raise
    end

    # Runs the script; returns its failure message, or nil if it ended normally.
    def run_script
      load(@path, ScriptContext.build(self))
      nil
    rescue SystemExit
      nil
    rescue *STOPPED
      raise
    rescue ScriptAbort => e
      e.message
    rescue Exception => e # rubocop:disable Lint/RescueException -- report SyntaxError and friends too
      describe(e)
    end

    # A script resumed after afterburner came back whose code now needs more RAM
    # than its process claimed. The game would stop it at the first call over;
    # end it here instead, quietly, saying how to pick up the new code.
    def outgrown(needed)
      @log.warn("[#{label}] not resumed: it now needs #{needed} GB and its stub claimed #{@claim} GB; run it again")
      deliver(op: "exit", message: "afterburner: #{@script} now needs #{needed} GB, more than this process " \
                                   "claimed (#{@claim} GB). Run it again to use the new code.")
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
      rescue *STOPPED
        raise
      rescue Exception => e # rubocop:disable Lint/RescueException
        @log.warn("[#{label}] at_exit hook raised #{e.class}: #{e.message}")
      end
    end

    # "boom (RuntimeError)" plus the backtrace through the script's own files,
    # the way Ruby prints an uncaught exception. If none of the frames are the
    # script's (the error came from a gem, say), the first few of any.
    def describe(error)
      root = "#{@scripts.root}/"
      trace = error.backtrace || []
      frames = trace.filter_map { _1.delete_prefix(root) if _1.start_with?(root) }
      frames = trace.first(3) if frames.empty?
      ["#{error.message} (#{error.class})", *frames.map { "\tfrom #{_1}" }].join("\n")
    end

    def deliver(message)
      @log.debug { "[#{label}] → #{JSON.generate(message)[0, 200]}" }
      Protocol::WebSocket::TextMessage.generate(message).send(@connection)
      @connection.flush
    rescue StandardError
      nil # the game already hung up
    end

    # The next message, or nil once the connection closes. A frame that isn't
    # JSON is skipped rather than taken for a hang-up.
    def receive
      loop do
        message = @connection.read or return nil
        @log.debug { "[#{label}] ← #{message.to_str[0, 200]}" }
        return JSON.parse(message.to_str)
      rescue JSON::ParserError
        @log.warn("[#{label}] ignored a message that wasn't JSON")
      end
    rescue *STOPPED
      raise
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
end
