# frozen_string_literal: true

module Afterburner
  # The game threw an error from an ns call, e.g. hacking a server you don't
  # have root on. The message is the game's.
  class NetscriptError < StandardError
    # The game wraps errors as "RUNTIME ERROR\nscript.js@home (PID - 3)\n\n<what
    # went wrong>"; a script only needs what went wrong.
    def self.from_game(text)
      new(text.to_s.sub(/\ARUNTIME ERROR\n[^\n]*\(PID - \d+\)\n+/, "").strip)
    end
  end

  # `ns` in a Ruby script. Every Netscript function is here under its
  # snake_case name, and the call goes to the game:
  #
  #   ns.hack("n00dles")                     # ns.hack
  #   ns.server_max_money("n00dles")         # ns.getServerMaxMoney
  #   ns.root_access?("n00dles")             # ns.hasRootAccess
  #   ns.hacknet.num_nodes                   # ns.hacknet.numNodes
  #   ns.hack("n00dles", additional_msec: 50) # options as keyword arguments
  #   ns.getServerMaxMoney("n00dles")        # the JavaScript name works too
  #
  # Objects come back as Records (server.money_max). It's a BasicObject so
  # that names like print, format, and sleep reach the game, not Kernel.
  class NS < BasicObject
    def initialize(session, api, path = [])
      @session = session
      @api = api
      @path = path
      @namespaces = {}
    end

    def method_missing(name, *args, **options, &block)
      entry = @api.resolve(@path, name)
      ::Kernel.raise ::NoMethodError.new(undefined_message(name), name) unless entry

      case entry.kind
      when :namespace then @namespaces[entry.path.last] ||= NS.new(@session, @api, entry.path)
      when :property then @session.property(entry.path)
      else call(entry, args, options, block)
      end
    end

    def respond_to?(name, _include_all = false)
      %i[inspect to_s respond_to?].include?(name.to_sym) || !@api.resolve(@path, name).nil?
    end

    def inspect = "#<NS #{['ns', *@path].join('.')}>"
    alias to_s inspect

    private

    def call(entry, args, options, block)
      # The game's atExit takes a JavaScript function, which can't cross the
      # bridge, so the block runs here when the script ends.
      return @session.at_exit(&block) if entry.path == ["atExit"]
      ::Kernel.raise ::ArgumentError, "ns.#{entry.qualified_name} doesn't take a block" if block

      args << options unless options.empty?
      @session.call(entry.path, args)
    end

    def undefined_message(name)
      message = "#{inspect} has no function `#{name}'"
      suggestions = @api.suggestions(@path, name)
      suggestions.empty? ? message : "#{message}. Did you mean? #{suggestions.join(', ')}"
    end
  end
end
