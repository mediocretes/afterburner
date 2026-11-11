# frozen_string_literal: true

require "async"
require "async/condition"
require "async/http/endpoint"
require "async/http/server"
require "async/variable"
require "async/websocket/adapters/http"
require "fileutils"
require "json"
require "logger"
require "protocol/http/response"
require "set"
require "uri"

module Afterburner
  class PortInUse < StandardError; end

  # One local server for everything, on one port (12525 by default, the same
  # as bitburner-filesync, which it replaces):
  #
  #   ws  /           the game's Remote API connection (GameLink)
  #   ws  /script     a running script's stub (Session), or the console's stub
  #   ws  /console    `afterburner console`
  #   GET /save       `afterburner save`: the live save file
  #   GET /ram?file=  `afterburner ram`: the game's own RAM figure for a script
  #   GET /sources    `afterburner restore`: the save's copies of the Ruby scripts
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
    # Fewer functions than this in the definitions means the parser has
    # probably fallen behind a change in the file's format.
    EXPECTED_FUNCTIONS = 300
    DEFINITIONS_PATIENCE = 30
    # Seconds without another script reconnecting before the resumes are reported.
    RESUME_QUIET = 3

    def initialize(config, log:)
      @config = config
      @log = log
      @origins = DEFAULT_ORIGINS + config.origins
      @scripts = Scripts.new(config.src)
      RedefinitionWarnings.serve(@scripts.root)
      @costs = RamCosts.new(config.costs)
      @stubs = Stubs.new(scripts: @scripts, definitions: config.definitions, costs: @costs, port: config.port,
                         twins: [config.dist, config.src].compact, log:)
      @files = config.dist && FileSync.new(root: config.dist, extensions: config.extensions, exclude: config.exclude,
                                           allow_deleting: config.allow_deleting, log:)
      @backup = SourceBackup.new(scripts: @scripts, log:)
      @link = nil
      @console_stub = nil # the console script in the game, attached or parked
      @console_client = nil # the `afterburner console` attached to it, or waiting for it
      @console_arrived = Async::Condition.new
      @sessions = Set.new
      @stamps = nil
      @resumes = 0
    end

    # Serves until the task running it is stopped: Sync { server.run }.
    def run
      endpoint = Async::HTTP::Endpoint.parse("http://localhost:#{@config.port}")
      bound = bind(endpoint)
      listener = Async { Async::HTTP::Server.new(method(:handle), bound, protocol: endpoint.protocol, scheme: endpoint.scheme).run }
      @log.info("listening on localhost:#{@config.port}; in the game, connect Options → Remote API to port #{@config.port}")
      loop do
        begin
          tick
        rescue StandardError => e
          # One broken step mustn't stop the server; say so and keep going.
          @log.error("#{e.message} (#{e.class}) at #{e.backtrace&.first}")
        end
        sleep TICK
      end
    ensure
      listener&.stop
      bound&.close
    end

    def allowed_origin?(origin) = origin.nil? || @origins.include?(origin) || LOCAL_ORIGIN.match?(origin)

    def live_link = (@link unless @link.nil? || @link.closed?)

    private

    # Binds now, so a busy port is an error here rather than a quiet failure
    # in a background task.
    def bind(endpoint)
      endpoint.bound
    rescue Errno::EADDRINUSE
      raise PortInUse, "port #{@config.port} is already in use; is bitburner-filesync, or another afterburner, still running?"
    end

    def tick
      link = live_link
      @files&.tick(link)
      @stubs.tick(link)
      @backup.tick(link)
      notice_changed_scripts
      report_resumes
    end

    # Ruby scripts reconnect on their own when afterburner comes back after a
    # restart, a few seconds apart. Once they've stopped arriving, say how many
    # in one line rather than one per script.
    def report_resumes
      return if @resumes.zero? || Time.now - @last_resume < RESUME_QUIET

      @log.info("#{@resumes} Ruby #{@resumes == 1 ? 'script' : 'scripts'} reconnected and started again from the top")
      @resumes = 0
    end

    # Hot reload. Libraries a running script has loaded are loaded again
    # first, so the restarted script sees their new code too.
    #
    # A changed library is required again whether or not anything is running,
    # so the next script to start gets the new code; restarting the scripts
    # that are running is what --no-reload turns off.
    def notice_changed_scripts
      stamps = @scripts.all_files.to_h { [_1, File.mtime(_1).to_f] if File.exist?(_1) }.compact
      changed = @stamps ? stamps.select { |file, stamp| @stamps.key?(file) && @stamps[file] != stamp }.keys : []
      @stamps = stamps
      return if changed.empty?

      reload_libraries(changed)
      return unless @config.reload

      @sessions.each { |session| session.reload(ram_api) if session.files.intersect?(changed) }
    end

    # Through require, not load: a plain load evaluates under the thread's
    # current top-level wrapper, which belongs to whichever script fiber last
    # entered a wrapped load, so the library would land inside that script's
    # module. require always evaluates at the real top level. Its constants
    # get redefined, which is the point; RedefinitionWarnings keeps Ruby quiet
    # about that.
    def reload_libraries(changed)
      loaded = $LOADED_FEATURES.to_set
      changed.select { loaded.include?(_1) }.each do |file|
        $LOADED_FEATURES.delete(file)
        require(file)
        @log.info("reloaded #{file.delete_prefix("#{@scripts.root}/")}")
      rescue ScriptError, StandardError => e
        @log.warn("reloading #{file.delete_prefix("#{@scripts.root}/")} failed: #{e.message}")
      end
    end

    def handle(request)
      uri = URI(request.path)
      origin = request.headers["origin"]&.to_s
      @log.debug { "#{request.method} #{uri.path} from origin #{origin.inspect}" }
      case uri.path
      when "/" then websocket(request, allowed_origin?(origin), origin) { attach_game(_1) }
      when "/script" then websocket(request, allowed_origin?(origin), origin) { run_script(_1) }
      when "/console" then websocket(request, origin.nil?, origin) { console(_1, query(uri)) }
      when "/save" then origin.nil? ? save_response : refuse(origin)
      when "/ram" then origin.nil? ? ram_response(query(uri)["file"]) : refuse(origin)
      when "/sources" then origin.nil? ? sources_response : refuse(origin)
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
      unless File.exist?(@config.definitions) && Afterburner.read_text(@config.definitions) == definitions
        FileUtils.mkdir_p(File.dirname(@config.definitions))
        File.write(@config.definitions, definitions)
        @log.info("saved the game's #{File.basename(@config.definitions)}")
      end
      count = api.functions.count
      if count < EXPECTED_FUNCTIONS
        @log.warn("found only #{count} functions in #{File.basename(@config.definitions)}; " \
                  "its format may have changed. Please report this to afterburner.")
      end
      @files&.push_all(link)
      @stubs.push_all(link)
      @backup.push_all(link)
      @stubs.refresh_proxy_copies(link)
    rescue GameLink::Error => e
      @log.warn("syncing with the game failed: #{e.message}")
    end

    # -- Scripts ---------------------------------------------------------------

    def run_script(connection)
      start = read_json(connection) or return
      return serve_console_stub(connection, start) if start["script"] == Stubs::CONSOLE_SCRIPT

      # Right after a save loads, scripts can start before the game's Remote
      # API has reconnected and sent its definitions; give it a moment.
      deadline = Time.now + DEFINITIONS_PATIENCE
      sleep TICK until File.exist?(@config.definitions) || Time.now > deadline
      unless File.exist?(@config.definitions)
        return say(connection, op: "fail", message: "afterburner doesn't have the game's definitions yet. " \
                                                    "Reconnect under Options → Remote API, then run this again.")
      end

      if start["resumed"]
        @resumes += 1
        @last_resume = Time.now
      end
      session = Session.new(connection, api:, scripts: @scripts, costs: @costs, ram_api:, log: @log)
      @sessions << session
      session.run(start)
    ensure
      @sessions.delete(session) if session
    end

    # Names and costs, with costs measured in the game where there are any.
    def ram_api
      key = [File.mtime(@config.definitions), @costs.load]
      @ram_api = nil unless @ram_api_key == key
      @ram_api_key = key
      @ram_api ||= Api.load(@config.definitions, measured: @costs.load)
    end

    def api
      mtime = File.mtime(@config.definitions)
      @api = nil if @api_mtime != mtime
      @api_mtime = mtime
      @api ||= Api.load(@config.definitions)
    end

    # -- The console -----------------------------------------------------------
    #
    # The console script in the game (afterburner/console.js) outlives any one
    # `afterburner console`. Leaving the console parks it, still holding its
    # RAM, and the next console attaches to it without another `run` in the
    # game. If afterburner restarts, it reconnects like any stub, and a console
    # that's still open reattaches. It ends when it's killed in the game, or by
    # AB.end_console. A second console script finds one running and ends.
    #
    # Each attach is a session: afterburner sends the stub {op: "attach",
    # session: n} and relays nothing from it until it echoes {op: "attached",
    # session: n}. The stub handles one message at a time, so anything it sends
    # before the echo (the answer to a call the last console left in flight)
    # is dropped instead of reaching the new console.

    ConsoleStub = Struct.new(:socket, :pid, :ram, :client, :session, :ready, :ended, :changed)

    # How long a console reattaching after a restart waits for the console
    # script to reconnect before asking you to run one; how long an attach
    # waits on a call in progress before saying so.
    REJOIN_PATIENCE = 6
    BUSY_NOTICE = 1

    # The console script's connection: owned here for its whole life, parked
    # or attached, so a script killed in the game is noticed even while parked.
    def serve_console_stub(socket, start)
      if (running = @console_stub)
        return say(socket, op: "exit", message: "afterburner: console script pid #{running.pid} is already running, so " \
                                                "this one isn't needed.")
      end

      stub = ConsoleStub.new(socket, start["pid"], start["ram"], nil, 0, false, false, Async::Condition.new)
      @console_stub = stub
      @log.info("console script pid #{stub.pid} #{start['resumed'] ? 'reconnected' : 'is running'} (#{stub.ram} GB)")
      @console_arrived.signal
      while (message = read_json(socket))
        from_console_stub(stub, message)
      end
      closed_by_script = true
    ensure
      console_stub_ended(stub, closed_by_script:) if stub
    end

    def from_console_stub(stub, message)
      if message["op"] == "attached"
        stub.ready = true if message["session"] == stub.session
        stub.changed.signal
      elsif stub.ready && stub.client
        say(stub.client, message)
      end
    end

    # closed_by_script: the script's side closed. Otherwise afterburner itself
    # is stopping, and the console notices that for itself.
    def console_stub_ended(stub, closed_by_script:)
      stub.ended = true
      @console_stub = nil if @console_stub.equal?(stub)
      stub.changed.signal
      @log.info("console script pid #{stub.pid} ended") if closed_by_script
      return unless closed_by_script && (client = stub.client)

      # Free the slot before the console reconnects, or it could be refused as
      # "another console" by its own old connection.
      @console_client = nil if @console_client.equal?(client)

      say(client, op: "detached", message: "The console script stopped in the game.")
      client.close
    rescue StandardError
      nil
    end

    # `afterburner console` connects here: ?ram= only if you gave --ram, and
    # ?rejoin=1 when it's reconnecting after losing afterburner or the script.
    def console(client, params)
      return say(client, op: "error", message: "Another console is already open.") if @console_client

      begin
        claim = ConsoleClaim.parse(params["ram"] || ConsoleClaim::DEFAULT)
      rescue ArgumentError => e
        return say(client, op: "error", message: e.message)
      end
      @console_client = client
      existing = !@console_stub.nil?
      waiting = Async { find_console_stub(client, claim, rejoin: params.key?("rejoin")) }
      # The console sends nothing until it's attached, so a read that ends
      # means you left while it was waiting.
      left = Async do
        client.read
        waiting.stop
      end
      stub = waiting.wait
      left.stop
      return unless stub && attach_console(stub, client, ram_note: existing && params.key?("ram"))

      relay_console(stub, client)
    ensure
      @console_client = nil if @console_client.equal?(client)
      park_console(stub, client) if stub
    end

    def find_console_stub(client, claim, rejoin:)
      if rejoin && !@console_stub
        say(client, op: "status", message: "Waiting for the console script to reconnect...")
        wait_for_console_stub(REJOIN_PATIENCE)
      end
      return @console_stub if @console_stub

      announced = false
      until (link = live_link) || @console_stub
        say(client, op: "status", message: "Waiting for the game to connect its Remote API to port #{@config.port}...") unless announced
        announced = true
        sleep TICK
      end
      unless @console_stub
        link.push_file(Stubs::CONSOLE, @stubs.console_source(claim))
        say(client, op: "status", message: "In the game, run: run #{Stubs::CONSOLE} (it claims #{claim}; change that with --ram)")
      end
      wait_for_console_stub until @console_stub
      @console_stub
    rescue GameLink::Error => e
      say(client, op: "error", message: e.message)
      nil
    end

    def wait_for_console_stub(seconds = nil)
      return @console_arrived.wait unless seconds

      Async::Task.current.with_timeout(seconds) { @console_arrived.wait until @console_stub }
    rescue Async::TimeoutError
      nil
    end

    def attach_console(stub, client, ram_note:)
      stub.client = client
      stub.ready = false
      session = (stub.session += 1)
      say(stub.socket, op: "attach", session:)
      noticed = false
      until stub.ready || stub.ended
        begin
          Async::Task.current.with_timeout(BUSY_NOTICE) { stub.changed.wait }
        rescue Async::TimeoutError
          unless noticed
            say(client, op: "status", message: "The console script is finishing a call the last console started; " \
                                               "attaching when it's done...")
          end
          noticed = true
        end
      end
      return false if stub.ended

      @log.info("console attached to pid #{stub.pid} (#{stub.ram} GB)")
      note = "--ram applies when a console script starts; this one already holds #{stub.ram} GB (AB.end_console ends it)." if ram_note
      say(client, op: "attached", pid: stub.pid, ram: stub.ram, note:)
      true
    end

    def relay_console(stub, client)
      while (message = read_json(client))
        case message["op"]
        when "call" then say(stub.socket, message)
        when "end_console"
          @log.info("console script pid #{stub.pid} ended from the console")
          say(stub.socket, op: "exit", message: "afterburner: ended from the console (AB.end_console).")
        end
      end
    end

    # You left the console; the console script waits for the next one.
    def park_console(stub, client)
      return unless stub.client.equal?(client)

      stub.client = nil
      stub.ready = false
      @log.info("console left; console script pid #{stub.pid} stays running for the next one") unless stub.ended
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

    def sources_response
      link = live_link or return text(503, "The game isn't connected to afterburner.\n")
      saved = SourceBackup.saved(link).map(&:to_h)
      Protocol::HTTP::Response[200, { "content-type" => "application/json" }, [JSON.generate(saved)]]
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
