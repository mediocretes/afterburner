# frozen_string_literal: true

require "async"
require "async/variable"
require "json"
require "protocol/websocket/message"

module Afterburner
  # The game's Remote API connection. The game is the WebSocket client: you
  # enter afterburner's port under Options → Remote API, and it connects here.
  # Then afterburner sends it JSON-RPC requests (pushFile, deleteFile,
  # getDefinitionFile, getSaveFile, calculateRam, ...) and it answers.
  class GameLink
    class Error < StandardError; end

    TIMEOUT = 30

    def initialize(connection)
      @connection = connection
      @next_id = 0
      @pending = {}
      @writing = Thread::Mutex.new
      @closed = false
    end

    # Reads the game's answers until it disconnects. Run it in its own task.
    def run
      while (message = @connection.read)
        reply = begin
          JSON.parse(message.to_str)
        rescue JSON::ParserError
          next # not ours to answer; keep listening
        end
        @pending.delete(reply["id"])&.resolve(reply) if reply.is_a?(Hash)
      end
    rescue *STOPPED
      raise
    rescue StandardError
      nil
    ensure
      @closed = true
      @pending.each_value { _1.resolve("error" => "the game disconnected") }
      @pending.clear
    end

    def closed? = @closed

    def close
      @connection.close
    rescue StandardError
      nil
    end

    def request(method, params = nil)
      raise Error, "the game isn't connected" if @closed

      id = (@next_id += 1)
      answer = Async::Variable.new
      @pending[id] = answer
      transmit({ jsonrpc: "2.0", id:, method:, params: }.compact)
      reply = Async::Task.current.with_timeout(TIMEOUT) { answer.wait }
      raise Error, "#{method}: #{reply['error']}" if reply["error"]

      reply["result"]
    rescue Async::TimeoutError
      @pending.delete(id)
      raise Error, "#{method}: the game didn't answer within #{TIMEOUT} seconds"
    end

    def push_file(name, content) = request("pushFile", { filename: name, content:, server: "home" })
    def delete_file(name) = request("deleteFile", { filename: name, server: "home" })
    def definitions = request("getDefinitionFile")
    def all_files = request("getAllFiles", { server: "home" })
    def all_file_metadata = request("getAllFileMetadata", { server: "home" })
    def calculate_ram(name) = request("calculateRam", { filename: name, server: "home" })

    # The live save, as the bytes an in-game export would give you.
    def save
      result = request("getSaveFile")
      data = result.fetch("save")
      # A binary save comes as a string with one character per byte.
      result["binary"] ? data.encode(Encoding::ISO_8859_1).b : data
    end

    private

    def transmit(message)
      @writing.synchronize do
        Protocol::WebSocket::TextMessage.generate(message).send(@connection)
        @connection.flush
      end
    end
  end
end
