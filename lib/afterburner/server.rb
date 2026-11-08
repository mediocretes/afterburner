# frozen_string_literal: true

require "async"
require "async/http/endpoint"
require "async/http/server"
require "async/variable"
require "async/websocket/adapters/http"
require "fileutils"
require "json"
require "logger"
require "protocol/http/response"
require "uri"

module Afterburner
  # One local server for everything, on one port (12525 by default, the same
  # as bitburner-filesync, which it replaces):
  #
  #   ws  /           the game's Remote API connection (GameLink)
  #   ws  /script     a running script's stub (Session), or the console's stub
  #   ws  /console    `afterburner console`
  #   GET /save       `afterburner save`: the live save file
  #   GET /ram?file=  `afterburner ram`: the game's own RAM figure for a script
  #
  # It listens on localhost only. Browser connections have to come from the
  # game's own pages, so another website open in the same browser can't drive
  # it, and the console, /save, and /ram refuse browsers outright.
  class Server
    # The web build, and the Steam build, which loads the game from a file.
    DEFAULT_ORIGINS = ["https://bitburner-official.github.io", "file://"].freeze
    # A game built from source and served locally, e.g. a fork.
    LOCAL_ORIGIN = %r{\Ahttps?://(localhost|127\.0\.0\.1)(:\d+)?\z}
    TICK = 0.5

    def initialize(config, log:, origins: DEFAULT_ORIGINS)
      @config = config
      @log = log
      @origins = origins
      @scripts = Scripts.new(config.src)
      @costs = RamCosts.new(config.costs)
      @stubs = Stubs.new(scripts: @scripts, definitions: config.definitions, costs: @costs, port: config.port,
                         twins: [config.dist, config.src].compact, log:)
      @files = config.dist && FileSync.new(root: config.dist, extensions: config.extensions, exclude: config.exclude,
                                           allow_deleting: config.allow_deleting, log:)
      @link = nil
      @console = nil
    end

    # Serves until the task running it is stopped: Sync { server.run }.
    def run
      endpoint = Async::HTTP::Endpoint.parse("http://localhost:#{@config.port}")
      listener = Async { Async::HTTP::Server.for(endpoint) { |request| handle(request) }.run }
      @log.info("listening on localhost:#{@config.port}; in the game, connect Options → Remote API to port #{@config.port}")
      loop do
        tick
        sleep TICK
      end
    ensure
      listener&.stop
    end

    def allowed_origin?(origin) = origin.nil? || @origins.include?(origin) || LOCAL_ORIGIN.match?(origin)

    def live_link = (@link unless @link.nil? || @link.closed?)

    private

    def tick
      link = live_link
      @files&.tick(link)
      @stubs.tick(link)
    end

    def handle(request)
      uri = URI(request.path)
      origin = request.headers["origin"]&.to_s
      case uri.path
      when "/" then websocket(request, allowed_origin?(origin), origin) { attach_game(_1) }
      when "/script" then websocket(request, allowed_origin?(origin), origin) { run_script(_1) }
      when "/console" then websocket(request, origin.nil?, origin) { console(_1, query(uri)["ram"]) }
      when "/save" then origin.nil? ? save_response : refuse(origin)
      when "/ram" then origin.nil? ? ram_response(query(uri)["file"]) : refuse(origin)
      else text(404, "afterburner: nothing at #{uri.path}\n")
      end
    rescue URI::InvalidURIError
      text(400, "afterburner: bad request\n")
    end

    def websocket(request, allowed, origin, &block)
      return refuse(origin) unless allowed

      Async::WebSocket::Adapters::HTTP.open(request, &block) or
        text(200, "afterburner #{VERSION}: connect the game's Remote API to this port\n")
    end

    # -- The game ------------------------------------------------------------

    def attach_game(connection)
      @link&.close
      link = GameLink.new(connection)
      @link = link
      @log.info("the game connected")
      reader = Async { link.run }
      Async { sync_everything(link) }
      reader.wait
    ensure
      @link = nil if @link.equal?(link)
      @log.info("the game disconnected")
    end

    # What a fresh connection needs: the game's current definitions, then
    # every file, the proxy, and every stub.
    def sync_everything(link)
      definitions = link.definitions
      unless File.exist?(@config.definitions) && File.read(@config.definitions) == definitions
        FileUtils.mkdir_p(File.dirname(@config.definitions))
        File.write(@config.definitions, definitions)
        @log.info("saved the game's #{File.basename(@config.definitions)}")
      end
      @files&.push_all(link)
      @stubs.push_all(link)
    rescue GameLink::Error => e
      @log.warn("syncing with the game failed: #{e.message}")
    end

    # -- Scripts ---------------------------------------------------------------

    def run_script(connection)
      start = read_json(connection) or return
      if start["script"] == Stubs::CONSOLE_SCRIPT
        attach_console_stub(connection, start)
      else
        Session.new(connection, api:, scripts: @scripts, costs: @costs, log: @log).run(start)
      end
    end

    def api
      mtime = File.mtime(@config.definitions)
      @api = nil if @api_mtime != mtime
      @api_mtime = mtime
      @api ||= Api.load(@config.definitions)
    end

    # -- The console -----------------------------------------------------------
    #
    # `afterburner console` connects here and waits; afterburner pushes a
    # console stub claiming the RAM asked for, and you run it in the game. Then
    # this relays: ns calls from your IRB to the stub, answers back.

    def console(client, ram)
      return say(client, op: "error", message: "Another console is already open.") if @console

      claim = Float(ram || 4)
      return say(client, op: "error", message: "--ram must be at least #{Api::BASE_RAM}") if claim < Api::BASE_RAM

      @console = Async::Variable.new
      announced = false
      until (link = live_link)
        say(client, op: "status", message: "Waiting for the game to connect its Remote API to port #{@config.port}...") unless announced
        announced = true
        sleep TICK
      end
      link.push_file(Stubs::CONSOLE, @stubs.console_source(claim))
      say(client, op: "status", message: "In the game, run: run #{Stubs::CONSOLE}")
      stub, start, done = @console.wait
      @log.info("console attached to pid #{start['pid']} (#{claim} GB)")
      say(client, op: "attached", pid: start["pid"], ram: claim)
      relay(client, stub)
      done.resolve(true)
    rescue ArgumentError
      say(client, op: "error", message: "--ram must be a number of GB")
    ensure
      @console = nil
    end

    def attach_console_stub(stub, start)
      waiting = @console
      if waiting.nil? || @console_claimed.equal?(waiting)
        return say(stub, op: "fail", message: "No console is waiting for this. Run `afterburner console` first.")
      end

      @console_claimed = waiting
      done = Async::Variable.new
      waiting.resolve([stub, start, done])
      done.wait
    end

    def relay(client, stub)
      upstream = Async do
        while (message = client.read)
          forward(stub, message)
        end
        say(stub, op: "exit") # you left the console; let the stub end
      end
      while (message = stub.read)
        forward(client, message)
      end
      say(client, op: "ended", message: "The console script stopped in the game.")
    ensure
      upstream&.stop
    end

    # -- Local tools -----------------------------------------------------------

    def save_response
      link = live_link or return text(503, "The game isn't connected to afterburner.\n")
      data = link.save
      extension = data.b.start_with?("\x1F\x8B".b) ? ".json.gz" : ".json"
      Protocol::HTTP::Response[200, { "content-type" => "application/octet-stream",
                                      "x-afterburner-filename" => "bitburnerSave_#{Time.now.to_i}#{extension}" }, [data]]
    rescue GameLink::Error => e
      text(502, "#{e.message}\n")
    end

    def ram_response(file)
      link = live_link or return text(503, "The game isn't connected to afterburner.\n")
      return text(400, "Which file? /ram?file=name.js\n") if file.to_s.empty?

      Protocol::HTTP::Response[200, { "content-type" => "application/json" }, [JSON.generate(link.calculate_ram(file))]]
    rescue GameLink::Error => e
      text(422, "#{e.message}\n")
    end

    # -- Plumbing --------------------------------------------------------------

    def query(uri) = URI.decode_www_form(uri.query.to_s).to_h

    def refuse(origin)
      @log.warn("refused a connection from #{origin.inspect}")
      text(403, "afterburner doesn't take connections from #{origin.inspect}\n")
    end

    def text(status, body) = Protocol::HTTP::Response[status, { "content-type" => "text/plain" }, [body]]

    def read_json(connection)
      message = connection.read or return nil
      JSON.parse(message.to_str)
    rescue StandardError
      nil
    end

    def say(connection, message)
      Protocol::WebSocket::TextMessage.generate(message).send(connection)
      connection.flush
    rescue StandardError
      nil
    end

    def forward(connection, message)
      message.send(connection)
      connection.flush
    end
  end
end
