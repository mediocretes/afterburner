# frozen_string_literal: true

require "async"
require "async/http/endpoint"
require "async/websocket/client"
require "json"
require "logger"
require "protocol/websocket/message"
require "uri"

module Afterburner
  # `afterburner console`: IRB on your machine, with `ns` live in the game.
  #
  # The first time, afterburner pushes a console script that claims the RAM you
  # ask for, and you run it in the game. It keeps running when you leave, so
  # the next console attaches to it straight away. By default it claims 80% of
  # the RAM free where it runs; --ram sets GB or another percentage. The game
  # charges each new function you call against that claim, and stops the
  # script if you go over.
  #
  # The console stays open when afterburner restarts or the console script
  # stops: it reconnects in the background and reattaches, and an ns call made
  # meanwhile waits for it (Ctrl-C gives up). Library files you've loaded from
  # the scripts folder are loaded again before each command if they changed.
  class Console
    # Loaded to make the prompt's binding; see prompt_binding.
    PROMPT = File.expand_path("console_prompt.rb", __dir__)
    # Seconds between tries to reach afterburner while it's away.
    RETRY = 2

    # src: the scripts folder, which require_relative and load at the prompt
    # resolve against, and whose loaded files are reloaded when they change.
    # ram: what --ram said, or nil.
    def initialize(port:, ram:, definitions:, src: nil, out: $stdout, input: $stdin)
      @port = port
      @ram = ram
      @definitions = definitions
      @root = src && File.expand_path(src)
      @out = out
      @input = input
      @next_id = 0
      @lock = Thread::Mutex.new
      @changed = Thread::ConditionVariable.new
      @replies = Thread::Queue.new
      @requests = nil
      @attached = false
      @ever_attached = false
      @leaving = false
      @fatal = nil
      @waiting_for = nil # the id of the call waiting for an answer
      @loaded = {} # library file → mtime when last loaded
    end

    # Returns true if a console session ran.
    def run
      @thread = Thread.new { stay_connected }
      return false unless first_attach

      @api = Api.load(@definitions)
      start_irb(NS.new(self, @api))
      true
    ensure
      leave
    end

    # What NS needs from a session. Waits for the console to be attached.
    def call(path, args)
      requests = wait_until_attached
      id = @lock.synchronize { @waiting_for = (@next_id += 1) }
      requests.push({ op: "call", id:, path:, args: Codec.encode(args) })
      loop do
        reply = @replies.pop
        if reply["op"] == "lost"
          raise NetscriptError, "the console lost the game during this call, so it may or may not have happened"
        end
        next unless reply["id"] == id

        raise NetscriptError.from_game(reply["message"]) if reply["op"] == "error"

        return Codec.decode(reply["value"])
      end
    ensure
      @lock.synchronize { @waiting_for = nil }
    end

    def property(path)
      case path
      when ["pid"] then @pid
      when ["args"] then []
      else call(path, [])
      end
    end

    def at_exit(&) = raise(ArgumentError, "at_exit is for scripts, not the console")

    # ARGV at the prompt: a console has no arguments.
    def args = []

    attr_reader :ns, :api

    # AB.end_console: ends the console script in the game, freeing its RAM.
    # The console stays open and attaches to the next one you run.
    def end_console
      wait_until_attached.push({ op: "end_console" })
      nil
    end

    # The prompt's binding: a script's top level, made the way a script's is
    # (loaded wrapped in a fresh ScriptContext module), so what works at the
    # prompt works in a script, and afterburner's own classes stay out of the
    # way. Plus `ns` as a local, because IRB only tab-completes after a
    # variable or a constant; in a script it's a method, and the same object.
    #
    # require_relative and load resolve against the scripts folder, as for a
    # script at its top, so `require_relative 'lib/server'` (or load
    # "lib/server") works here as it does in src/foo.rb. Ruby's own would look
    # beside console_prompt.rb, which is in afterburner.
    def prompt_binding(ns)
      @context = context = ScriptContext.build(self)
      if (root = @root)
        context.define_method(:require_relative) { |path| require(File.expand_path(path, root)) }
        context.define_method(:load) do |file, wrap = false|
          path = Console.resolve(root, file)
          ScriptContext.load_at_top_level(path, wrap) { super(path, wrap) }.tap { ScriptContext.share(context) }
        end
      end
      load(PROMPT, context)
      top = Fiber[:afterburner_prompt]
      top.local_variable_set(:ns, ns)
      top
    ensure
      Fiber[:afterburner_prompt] = nil
    end

    # file relative to the scripts folder, .rb optional, if that's a file;
    # otherwise file as given.
    def self.resolve(root, file)
      base = File.expand_path(file.to_s, root)
      [base, "#{base}.rb"].find { File.file?(_1) } || file
    end

    # Before each command: library files from the scripts folder that changed
    # since they were loaded are loaded again, so the command sees the new
    # code. Like a reload in a running script, it reopens classes: a method
    # deleted from the file stays defined until the console restarts.
    def reload_changed_files
      loaded_library_files.each do |file|
        mtime = File.mtime(file)
        seen = @loaded[file]
        @loaded[file] = mtime
        reload(file) if seen && mtime != seen
      rescue SystemCallError
        nil
      end
    end

    # After each command: notes when files it loaded were last changed, so an
    # edit made before the next command counts as a change.
    def note_loaded_files
      loaded_library_files.each do |file|
        @loaded[file] ||= File.mtime(file)
      rescue SystemCallError
        nil
      end
    end

    def logger = @logger ||= Logger.new(@out, formatter: ->(_severity, _time, _program, message) { "#{message}\n" })

    # Prints a line now. The connection thread prints while IRB waits for
    # input, and piped output is buffered until something flushes it.
    def say(text)
      @out.puts(text)
      @out.flush
    end

    private

    # The background thread: connects, attaches, and when afterburner or the
    # console script goes away, tries again until you leave.
    def stay_connected
      until @leaving
        outcome = connect_once
        break if @leaving || outcome == :fatal

        sleep RETRY unless outcome == :again
      end
    end

    # One connection to afterburner. Returns :fatal (stop trying), :again (it
    # closed on purpose; reconnect now), or :lost.
    def connect_once
      requests = Thread::Queue.new
      @lock.synchronize { @requests = requests }
      query = { ram: @ram, rejoin: (1 if @ever_attached) }.compact
      endpoint = Async::HTTP::Endpoint.parse("http://localhost:#{@port}/console#{"?#{URI.encode_www_form(query)}" unless query.empty?}")
      outcome = :lost
      Sync do |task|
        Async::WebSocket::Client.connect(endpoint) do |connection|
          @away_said = false
          writer = task.async do
            while (request = requests.pop)
              Protocol::WebSocket::TextMessage.generate(request).send(connection)
              connection.flush
            end
            connection.close
          end
          while (message = connection.read)
            outcome = route(JSON.parse(message.to_str)) || outcome
          end
          writer.stop
        end
      end
      outcome
    rescue StandardError
      unless @away_said || @leaving
        say(@ever_attached ? "\nafterburner went away; reattaching when it's back..." :
                                   "Waiting for afterburner on port #{@port}. Is `afterburner watch` running? (Ctrl-C to stop)")
        @away_said = true
      end
      :lost
    ensure
      if detach && !@leaving && !@away_said
        say("\nafterburner went away; reattaching when it's back...")
        @away_said = true
      end
    end

    def route(message)
      case message["op"]
      when "status" then say(message["message"])
      when "attached" then attached(message)
      when "result" then @replies.push(message)
      when "error" then message.key?("id") ? @replies.push(message) : refused(message)
      when "detached"
        say("\n#{message['message']} Reattaching when one is running...")
        @away_said = true
        :again
      end
    end

    # Another console is attached: wait for it to leave (it may be the one you
    # just left, not yet noticed). --ram didn't parse: stop trying.
    def refused(message)
      if message["message"].to_s.include?("Another console")
        unless @away_said
          say(@ever_attached ? "\nAnother console is attached; reattaching when it leaves..." :
                               "Another console is attached; attaching when it leaves (Ctrl-C to stop)...")
        end
        @away_said = true
        return :lost
      end
      @lock.synchronize do
        @fatal = message["message"]
        @changed.broadcast
      end
      say(message["message"])
      :fatal
    end

    def attached(message)
      first = !@ever_attached
      @lock.synchronize do
        @pid = message["pid"]
        @replies.clear
        @attached = @ever_attached = true
        @changed.broadcast
      end
      if first
        say("Attached to pid #{@pid}, with #{message['ram']} GB claimed. `ns` is live; `exit` to leave " \
                  "(the console script keeps running; AB.end_console ends it).")
      else
        say("\nReattached to the console script (pid #{@pid}).")
      end
      say(message["note"]) if message["note"]
      nil
    end

    # Not attached any more: a call waiting for an answer won't get one.
    # Returns whether it was attached.
    def detach
      @lock.synchronize do
        was = @attached
        @replies.push({ "op" => "lost" }) if was && @waiting_for
        @attached = false
        @changed.broadcast
        was
      end
    end

    def first_attach
      @lock.synchronize do
        @changed.wait(@lock) until @attached || @fatal
        !@fatal
      end
    end

    # The queue for this connection's requests, once attached.
    def wait_until_attached
      @lock.synchronize do
        unless @attached || @fatal
          say("(waiting for the console to reattach; Ctrl-C to give up)")
          @changed.wait(@lock) until @attached || @fatal
        end
        raise NetscriptError, "the console can't reattach: #{@fatal}" if @fatal

        @requests
      end
    end

    # Says so before closing, so afterburner parks the console script at once
    # rather than whenever it notices the connection close.
    def leave
      @leaving = true
      @lock.synchronize do
        @requests&.push({ op: "leave" }) if @attached
        @requests&.push(nil)
      end
      @thread&.join(2)
      @thread&.kill
    end

    def loaded_library_files
      return [] unless @root

      prefixes = [@root, (File.realpath(@root) rescue @root)].uniq.map { "#{_1}/" }
      $LOADED_FEATURES.select { |file| file.end_with?(".rb") && prefixes.any? { file.start_with?(_1) } }
    end

    def reload(file)
      shown = file.delete_prefix("#{@root}/")
      $LOADED_FEATURES.delete(file)
      Kernel.require(file)
      ScriptContext.share(@context) if @context
      say("(reloaded #{shown})")
    rescue ScriptError, StandardError => e
      $LOADED_FEATURES << file unless $LOADED_FEATURES.include?(file)
      say("(reloading #{shown} failed, so the previous version stays: #{e.message.lines.first&.chomp})")
    end

    # Around each command IRB evaluates: reloads what changed before it, and
    # notes what it loaded after it.
    module ReloadBeforeEachCommand
      def evaluate(...)
        session = Fiber[:afterburner_session]
        session.reload_changed_files if session.is_a?(Console)
        super
      ensure
        session.note_loaded_files if session.is_a?(Console)
      end
    end

    def start_irb(ns)
      require "irb"
      @ns = ns
      RedefinitionWarnings.serve(@root) if @root
      IRB::Context.prepend(ReloadBeforeEachCommand) unless IRB::Context < ReloadBeforeEachCommand
      # As in a script: `ns` and `logger` also work inside methods and classes
      # you define here.
      Fiber[:afterburner_session] = self
      prompt_binding(ns).irb(show_code: false)
    end
  end
end
