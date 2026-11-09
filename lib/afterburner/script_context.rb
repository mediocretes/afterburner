# frozen_string_literal: true

require "stringio"

module Afterburner
  # The top-level context a script runs in. Each run gets a fresh module, so
  # constants and methods a script defines don't leak into other scripts.
  module ScriptContext
    def self.build(session)
      shared = top_level_modules
      Module.new do
        context = self
        shared.each { |name, value| const_set(name, value) }
        const_set(:ARGV, session.args.dup.freeze)
        const_set(:NetscriptError, Afterburner::NetscriptError)
        define_method(:at_exit) { |&block| session.at_exit(&block) }
        define_method(:abort) { |message = "aborted"| raise ScriptAbort, message }
        define_method(:exit!) { |*| raise SystemExit }

        # Loading code can define top-level classes after this module was
        # built: a library's Server, say. Share those too, so `class Server`
        # in the script reopens that one rather than making an empty one here.
        define_method(:require) { |name| super(name).tap { ScriptContext.share(context) } }
        define_method(:load) do |file, wrap = false|
          ScriptContext.load_at_top_level(file, wrap) { super(file, wrap) }.tap { ScriptContext.share(context) }
        end
        # Kernel#require_relative would resolve against this file; resolve
        # against the caller's, as Ruby's does, and share through require.
        define_method(:require_relative) do |path|
          base = caller_locations(1, 1).first&.absolute_path or raise LoadError, "cannot infer basepath"
          require(File.expand_path(path, File.dirname(base)))
        end
      end
    end

    # Kernel#load evaluates under the thread's current top-level wrapper, and
    # while another script sits paused inside its own wrapped load, that's the
    # other script's module: the file's classes would land there. require
    # always evaluates at the real top level, so a .rb file is loaded through
    # it, forgotten first so it runs again, as load always does. Anything else
    # (another extension, or wrap) goes to Kernel#load.
    def self.load_at_top_level(file, wrap)
      path = File.expand_path(file.to_s)
      return yield if wrap || !path.end_with?(".rb") || !File.file?(path)

      [path, File.realpath(path)].each { $LOADED_FEATURES.delete(_1) }
      require(path)
      true
    end

    # Adds the top-level classes and modules defined since context was built,
    # leaving alone any name the script has defined for itself.
    def self.share(context)
      top_level_modules.each { |name, value| context.const_set(name, value) unless context.const_defined?(name, false) }
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

  # `ns` and `logger` anywhere in a running script's code: the script itself,
  # its libraries, its classes, a method it adds to Numeric. Each script gets
  # its own, found through the fiber it runs in, which is also how `puts` finds
  # the right terminal; tasks a script starts inherit it. Outside a running
  # script (and in a Thread a script starts) there's no game to talk to.
  module ScriptAccess
    private

    def ns = Afterburner::ScriptAccess.current(:ns).ns
    def logger = Afterburner::ScriptAccess.current(:logger).logger

    def self.current(name)
      Fiber[:afterburner_session] or
        raise NameError.new("`#{name}` is only available while a Ruby script is running in the game", name)
    end
  end
  ::Kernel.include(ScriptAccess)

  # Drops Ruby's warnings about redefined constants ("already initialized
  # constant", "previous definition of") when they come from a file under a
  # scripts folder afterburner serves. Libraries are evaluated at the real top
  # level and loaded again when they change, and Ruby's own classes are shared
  # by every run, so a constant in a library or a monkeypatch is redefined as a
  # matter of course; the warning would only land in a script's terminal. Any
  # other warning, and these from anywhere else, pass through.
  module RedefinitionWarnings
    REDEFINED = /\A[^\n]*?:\d+: warning: (?:already initialized constant|previous definition of) /

    @roots = Set.new

    def self.serve(root)
      @roots << "#{File.expand_path(root)}/"
      @roots << "#{File.realpath(root)}/" if File.exist?(root)
    end

    def self.drop?(message) = message.match?(REDEFINED) && @roots.any? { message.start_with?(_1) }

    def warn(message, category: nil, **)
      super unless RedefinitionWarnings.drop?(message.to_s)
    end
  end
  ::Warning.extend(RedefinitionWarnings)

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
