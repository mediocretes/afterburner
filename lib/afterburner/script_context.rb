# frozen_string_literal: true

require "stringio"

module Afterburner
  # The top-level context a script runs in. Each run gets a fresh module, so
  # constants and methods a script defines don't leak into other scripts.
  module ScriptContext
    def self.build(session)
      ns = session.ns
      logger = session.logger
      shared = top_level_modules
      Module.new do
        shared.each { |name, value| const_set(name, value) }
        const_set(:ARGV, session.args.dup.freeze)
        const_set(:NetscriptError, Afterburner::NetscriptError)
        define_method(:ns) { ns }
        define_method(:logger) { logger }
        define_method(:at_exit) { |&block| session.at_exit(&block) }
        define_method(:abort) { |message = "aborted"| raise ScriptAbort, message }
        define_method(:exit!) { |*| raise SystemExit }
      end
    end

    # Ruby's classes and modules, and any a library has defined. Inside a
    # script's module, `class Float` would otherwise make a new Float in that
    # module instead of reopening Ruby's (class definitions only look in the
    # module they're in), so a monkeypatch would silently do nothing. Classes
    # a script defines itself still stay its own.
    def self.top_level_modules
      verbose = $VERBOSE
      $VERBOSE = nil # some constants warn when looked up
      Object.constants.filter_map do |name|
        next if Object.autoload?(name)

        value = Object.const_get(name)
        [name, value] if value.is_a?(Module)
      rescue NameError, LoadError
        nil
      end
    ensure
      $VERBOSE = verbose
    end
  end

  # Stands in for $stdout and $stderr while afterburner serves. Writes from
  # inside a script go to that script's terminal output in the game; writes
  # from anywhere else go to the real stream. So puts, print, p, and warn work
  # in scripts, including inside classes and gems they call. Anything else
  # IO-like is passed through to the real stream.
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
    def putc(char) = write(render { _1.putc(char) }) && char

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

    def respond_to_missing?(name, include_private = false) = @real.respond_to?(name, include_private) || super

    def method_missing(name, ...)
      @real.respond_to?(name) ? @real.public_send(name, ...) : super
    end

    private

    def render
      io = StringIO.new
      yield io
      io.string
    end
  end
end
