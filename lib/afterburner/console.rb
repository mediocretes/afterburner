# frozen_string_literal: true

require "async"
require "async/http/endpoint"
require "async/websocket/client"
require "json"
require "logger"
require "protocol/websocket/message"

module Afterburner
  # `afterburner console`: IRB on your machine, with `ns` live in the game.
  #
  # afterburner pushes a console stub that claims the RAM you ask for, you run
  # it in the game, and from then on each ns call you type goes to it. The
  # game charges each new function you call against that claim, and stops the
  # stub if you go over; ask for more with --ram.
  class Console
    # Loaded to make the prompt's binding; see prompt_binding.
    PROMPT = File.expand_path("console_prompt.rb", __dir__)

    def initialize(port:, ram:, definitions:, out: $stdout, input: $stdin)
      @port = port
      @ram = ram
      @definitions = definitions
      @out = out
      @input = input
      @next_id = 0
      @ended = false
    end

    # Returns true if a console session ran.
    def run
      connect
      return false unless attached?

      @api = Api.load(@definitions)
      start_irb(NS.new(self, @api))
      true
    ensure
      @requests&.push(nil)
      @thread&.join(2)
    end

    # What NS needs from a session.
    def call(path, args)
      raise NetscriptError, "the console script has stopped" if @ended

      id = (@next_id += 1)
      @requests.push({ op: "call", id:, path:, args: Codec.encode(args) })
      reply = @replies.pop
      raise NetscriptError, reply["message"] if reply["op"] == "ended"
      raise NetscriptError.from_game(reply["message"]) if reply["op"] == "error"

      Codec.decode(reply["value"])
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

    # The prompt's binding: a script's top level, made the way a script's is
    # (loaded wrapped in a fresh ScriptContext module), so what works at the
    # prompt works in a script, and afterburner's own classes stay out of the
    # way. Plus `ns` as a local, because IRB only tab-completes after a
    # variable or a constant; in a script it's a method, and the same object.
    def prompt_binding(ns)
      load(PROMPT, ScriptContext.build(self))
      top = Fiber[:afterburner_prompt]
      top.local_variable_set(:ns, ns)
      top
    ensure
      Fiber[:afterburner_prompt] = nil
    end

    def logger = @logger ||= Logger.new(@out, formatter: ->(_severity, _time, _program, message) { "#{message}\n" })

    private

    # A background thread runs the WebSocket in its own reactor; IRB, on this
    # thread, talks to it through queues.
    def connect
      @requests = Thread::Queue.new
      @replies = Thread::Queue.new
      @events = Thread::Queue.new
      endpoint = Async::HTTP::Endpoint.parse("http://localhost:#{@port}/console?ram=#{@ram}")
      @thread = Thread.new do
        Sync do |task|
          Async::WebSocket::Client.connect(endpoint) do |connection|
            writer = task.async do
              while (request = @requests.pop)
                Protocol::WebSocket::TextMessage.generate(request).send(connection)
                connection.flush
              end
              connection.close
            end
            while (message = connection.read)
              route(JSON.parse(message.to_str))
            end
            writer.stop
          end
        end
      rescue StandardError => e
        @events.push("op" => "error", "message" => "Couldn't reach afterburner on port #{@port} (#{e.message}). Is `afterburner watch` running?")
      ensure
        stopped("Disconnected from afterburner.")
      end
    end

    def route(message)
      case message["op"]
      when "result", "error" then @replies.push(message)
      when "ended" then stopped(message["message"])
      else @events.push(message)
      end
    end

    def stopped(message)
      return if @ended

      @ended = true
      @out.puts("\n#{message}") if @pid
      @events.push("op" => "ended", "message" => message)
      @replies.push("op" => "ended", "message" => "the console script has stopped")
    end

    def attached?
      loop do
        event = @events.pop
        case event["op"]
        when "status" then @out.puts(event["message"])
        when "attached"
          @pid = event["pid"]
          @out.puts("Attached to pid #{@pid}, with #{event['ram']} GB claimed. `ns` is live; `exit` to leave.")
          return true
        else
          @out.puts(event["message"])
          return false
        end
      end
    end

    def start_irb(ns)
      require "irb"
      @ns = ns
      # As in a script: `ns` and `logger` also work inside methods and classes
      # you define here.
      Fiber[:afterburner_session] = self
      prompt_binding(ns).irb(show_code: false)
    end
  end
end
