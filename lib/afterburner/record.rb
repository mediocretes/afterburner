# frozen_string_literal: true

require "json"

module Afterburner
  # A game object (a server, the player, a running script, ...) as a Ruby
  # object with snake_case readers:
  #
  #   server = ns.server("n00dles")
  #   server.money_max         # moneyMax
  #   server.admin_rights?     # hasAdminRights
  #   server[:money_max]       # same as server.money_max
  #   server.to_h              # { hostname: "n00dles", money_max: 1750000, ... }
  #
  #   case ns.server(host)
  #   in { has_admin_rights: false } then ns.nuke(host)
  #   in { money_max: 0 } then logger.info "nothing to steal"
  #   end
  #
  # Passing one back to the game (formulas take servers and players) sends the
  # original object, camelCase keys and all.
  class Record
    def initialize(raw)
      @raw = raw.freeze
      @keys = raw.keys.to_h { [Api.underscore(_1), _1] }
    end

    def [](name)
      key = @raw.key?(name.to_s) ? name.to_s : @keys[name.to_s]
      Codec.decode(@raw[key]) if key
    end

    def key?(name) = @raw.key?(name.to_s) || @keys.key?(name.to_s)

    def to_h
      @keys.to_h { |snake, key| [snake.to_sym, deep_to_h(Codec.decode(@raw[key]))] }
    end

    def deconstruct_keys(_keys) = to_h

    def to_json(*args) = @raw.to_json(*args)

    def as_wire = @raw

    def ==(other) = other.is_a?(Record) && other.as_wire == @raw
    alias eql? ==

    def hash = @raw.hash

    def inspect
      fields = @keys.first(8).map { |snake, key| "#{snake}=#{@raw[key].inspect}" }
      fields << "..." if @keys.size > 8
      "#<Record #{fields.join(' ')}>"
    end
    alias to_s inspect

    def respond_to_missing?(name, include_private = false) = !lookup(name).nil? || super

    def method_missing(name, *args)
      key = lookup(name)
      return super if key.nil? || !args.empty?

      value = Codec.decode(@raw[key])
      name.end_with?("?") ? !!value : value
    end

    private

    # money_max → moneyMax; admin_rights? → hasAdminRights, backdoor_installed? → backdoorInstalled
    def lookup(name)
      name = name.to_s
      return @keys[name] unless name.end_with?("?")

      base = name.chomp("?")
      @keys[base] || @keys["has_#{base}"] || @keys["is_#{base}"]
    end

    def deep_to_h(value)
      case value
      when Record then value.to_h
      when Array then value.map { deep_to_h(_1) }
      else value
      end
    end
  end

  # Values on their way to and from the game. JSON can't carry Infinity or
  # NaN, which some game functions return, so both sides tag them as
  # {"$num": "Infinity"}.
  module Codec
    NON_FINITE = { "Infinity" => Float::INFINITY, "-Infinity" => -Float::INFINITY, "NaN" => Float::NAN }.freeze

    module_function

    # Ruby → wire. Hash keys go camelCase, so keyword options read like Ruby:
    # ns.hack(t, additional_msec: 50) sends {additionalMsec: 50}.
    def encode(value)
      case value
      when Record then value.as_wire
      when Hash then value.to_h { |k, v| [k.is_a?(Symbol) ? Api.camelize(k) : k.to_s, encode(v)] }
      when Array then value.map { encode(_1) }
      when Symbol then value.to_s
      when Float then value.finite? ? value : { "$num" => non_finite_name(value) }
      when Proc, Method then raise ArgumentError, "Ruby blocks and methods can't be sent to the game"
      else value
      end
    end

    # Wire → Ruby. Objects become Records.
    def decode(value)
      case value
      when Hash
        value.size == 1 && NON_FINITE.key?(value["$num"]) ? NON_FINITE[value["$num"]] : Record.new(value)
      when Array then value.map { decode(_1) }
      else value
      end
    end

    def non_finite_name(float)
      return "NaN" if float.nan?

      float.positive? ? "Infinity" : "-Infinity"
    end
  end
end
