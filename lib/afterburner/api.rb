# frozen_string_literal: true

require "did_you_mean"

module Afterburner
  # The Netscript API as the game's NetscriptDefinitions.d.ts describes it:
  # which names are functions, which are namespaces (ns.hacknet, ns.ui, ...),
  # what each function costs in RAM, and the Ruby names each one answers to.
  #
  # The ns proxy and the RAM scanner both resolve names through here, so any
  # name a script can call is a name the scanner charges for.
  class Api
    # Every script pays this before calling anything.
    BASE_RAM = 1.6

    # A function, namespace, or plain property of ns or one of its namespaces.
    # `path` is the JavaScript path from ns, e.g. ["hacknet", "numNodes"].
    Entry = Data.define(:kind, :path, :ram) do
      def function? = kind == :function
      def namespace? = kind == :namespace
      def property? = kind == :property

      # The name getFunctionRamCost and the game's error messages use.
      def qualified_name = path.join(".")
    end

    # measured: RAM costs the game reported (qualified name → GB), which win
    # over the documented ones. See RamCosts.
    def self.load(path, measured: {}) = new(Afterburner.read_text(path), measured:)

    def initialize(definitions, measured: {})
      @measured = measured
      @interfaces = DefinitionsParser.new(definitions).interfaces
      raise ArgumentError, "no NS interface in the definitions" unless @interfaces.key?("NS")

      @names = {}
    end

    # Resolves a Ruby method name called on ns (path []) or on a namespace
    # (path ["hacknet"]). Returns an Entry, or nil if nothing answers to it.
    def resolve(path, ruby_name)
      interface = interface_at(path) or return nil
      member = names_for(interface)[ruby_name.to_s] or return nil
      entry([*path, member.name], member)
    end

    # The RAM a script needs to use these functions (qualified names, as in
    # Entry#qualified_name): the base cost, plus each function once.
    def ram_for(names)
      @ram_table ||= functions.to_h { [_1.qualified_name, _1.ram || 0.0] }
      (BASE_RAM + names.uniq.sum { @ram_table.fetch(_1, 0.0) }).round(2)
    end

    # Ruby names close to ruby_name, for "did you mean" messages.
    def suggestions(path, ruby_name)
      interface = interface_at(path) or return []
      DidYouMean::SpellChecker.new(dictionary: names_for(interface).keys.grep(/\A[a-z]/)).correct(ruby_name.to_s)
    end

    # Every function in the API, as Entries, depth first.
    def functions(path = [], interface = @interfaces.fetch("NS"), &block)
      return enum_for(:functions, path, interface) unless block

      members_of(interface).each_value do |member|
        case kind_of(member)
        when :function then yield entry([*path, member.name], member)
        when :namespace then functions([*path, member.name], @interfaces.fetch(member.type), &block)
        end
      end
    end

    # The Ruby names a function answers to, preferred first.
    def self.ruby_names(name, returns_boolean:)
      snake = underscore(name)
      names = [snake]
      if returns_boolean && predicate?(name)
        names << "#{snake.sub(/\A(is|get)_/, '')}?"
        names << "#{snake.delete_prefix('has_')}?" if snake.start_with?("has_")
        names << "#{snake}?"
      elsif snake.start_with?("get_")
        names << snake.delete_prefix("get_")
      end
      names.uniq
    end

    # Functions that answer a yes/no question, rather than doing something and
    # reporting whether it worked (nuke, scp, kill...).
    def self.predicate?(name)
      name.match?(/\A(is|has|can|in|get)[A-Z0-9]/) || name.match?(/(Exists|Running|Enabled)\z/) || %w[empty full].include?(name)
    end

    def self.underscore(name)
      name.gsub(/([A-Z\d]+)([A-Z][a-z])/, '\1_\2').gsub(/([a-z\d])([A-Z])/, '\1_\2').downcase
    end

    def self.camelize(name)
      head, *rest = name.to_s.split("_")
      [head, *rest.map(&:capitalize)].join
    end

    private

    def entry(path, member)
      kind = kind_of(member)
      ram = kind == :function ? @measured.fetch(path.join("."), member.ram) : nil
      Entry.new(kind:, path:, ram:)
    end

    def interface_at(path)
      path.reduce(@interfaces.fetch("NS")) do |interface, segment|
        member = members_of(interface)[segment]
        return nil unless member && kind_of(member) == :namespace

        @interfaces.fetch(member.type)
      end
    end

    def kind_of(member)
      return :function if member.method?

      interface = @interfaces[member.type]
      interface && members_of(interface).each_value.any?(&:method?) ? :namespace : :property
    end

    # Members of an interface, including the ones it inherits.
    def members_of(interface)
      interface.parents.filter_map { @interfaces[_1] }.map { members_of(_1) }.reduce({}, :merge).merge(interface.members)
    end

    # Ruby name → member, for one interface. The exact JavaScript name and its
    # snake_case form always win; shorter aliases (get_ dropped, predicate ?)
    # are only added where they don't collide with anything.
    def names_for(interface)
      @names[interface.name] ||= begin
        members = members_of(interface).values
        table = {}
        members.each do |member|
          table[member.name] = member
          table[Api.underscore(member.name)] ||= member
        end
        aliases = Hash.new { |h, k| h[k] = [] }
        members.select(&:method?).each do |member|
          Api.ruby_names(member.name, returns_boolean: member.returns == "boolean").each { aliases[_1] << member }
        end
        aliases.each { |name, claimants| table[name] ||= claimants.first if claimants.uniq.size == 1 }
        table
      end
    end
  end

  # Reads the interfaces out of NetscriptDefinitions.d.ts. The file is
  # generated and consistently formatted (two-space indents, one member per
  # line, a JSDoc block with "RAM cost: N GB" before each function), so a line
  # scanner is enough; no TypeScript parser needed.
  class DefinitionsParser
    Interface = Struct.new(:name, :parents, :members)
    Member = Data.define(:name, :method, :type, :returns, :ram) do
      def method? = self.method
    end

    INTERFACE = /\A(?:export )?(?:declare )?interface (\w+)(?:<[^>]*>)?(?: extends (.+?))? \{\s*\z/

    def initialize(source)
      @lines = source.lines.map(&:chomp)
    end

    def interfaces
      @interfaces ||= begin
        found = {}
        index = 0
        while index < @lines.size
          if (match = INTERFACE.match(@lines[index]))
            parents = match[2].to_s.gsub(/<[^>]*>/, "").split(/,\s*/).map(&:strip).reject(&:empty?)
            interface = Interface.new(match[1], parents, {})
            index = parse_members(index + 1, interface, "  ", found)
            found[interface.name] = interface
          end
          index += 1
        end
        found
      end
    end

    private

    # Reads members at `indent` until the line that closes the block. Returns
    # the index of that closing line.
    def parse_members(index, interface, indent, found)
      closing = /\A#{indent.delete_suffix('  ')}\};?\s*\z/
      member_line = /\A#{indent}(?:readonly )?(\w+)\??(\(|<|: )/
      ram = nil
      while index < @lines.size
        line = @lines[index]
        return index if closing.match?(line)

        if line.start_with?("#{indent}/**")
          index, ram = read_doc(index)
        elsif (match = member_line.match(line))
          name, opener = match.captures
          if opener == ": " && line.end_with?("{")
            inline = Interface.new("#{interface.name}.#{name}", [], {})
            index = parse_members(index + 1, inline, "#{indent}  ", found)
            found[inline.name] = inline
            interface.members[name] = Member.new(name:, method: false, type: inline.name, returns: nil, ram: nil)
          else
            index, signature = read_signature(index)
            interface.members[name] ||= member_from(name, opener, signature, ram)
          end
          ram = nil
        end
        index += 1
      end
      index
    end

    def read_doc(index)
      ram = nil
      loop do
        line = @lines[index]
        ram = Float(Regexp.last_match(1)) if line =~ /RAM cost: ([\d.]+)/
        return [index, ram] if line.include?("*/")

        index += 1
      end
    end

    # A member's whole signature, which may span lines. Ends at the first ";"
    # outside any brackets.
    def read_signature(index)
      text = +""
      depth = 0
      loop do
        line = @lines[index]
        text << line.strip << " "
        depth += line.count("({[<") - line.count(")}]>") + line.scan("=>").size
        return [index, text.strip] if depth <= 0 && line.rstrip.end_with?(";")

        index += 1
      end
    end

    def member_from(name, opener, signature, ram)
      if opener == ": "
        type = signature.sub(/\A(?:readonly )?\w+\??: /, "").delete_suffix(";").strip
        Member.new(name:, method: false, type:, returns: nil, ram: nil)
      else
        returns = signature[/\)\s*:\s*([^;]+);\z/, 1]&.strip
        Member.new(name:, method: true, type: nil, returns:, ram:)
      end
    end
  end
end
