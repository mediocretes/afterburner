# frozen_string_literal: true

module Afterburner
  # AB: afterburner's own tools, kept beside ns so that ns holds only the game's
  # functions. Works in `afterburner console` and in running scripts:
  #
  #   AB.functions             # every function, with its RAM cost
  #   AB.functions(/server/)   # just the ones matching
  #   AB.doc(:scan)            # a function's Ruby call, signature, and docs
  #   AB.doc("cloud")          # a namespace's functions
  #
  # Names can be Ruby or JavaScript names, dotted through namespaces, with or
  # without "ns.": "cloud.server_names", "ns.hacknet.numNodes".
  module AB
    class << self
      # Prints every function whose Ruby or JavaScript name matches pattern
      # (a Regexp, or a String to look for), with its RAM cost.
      def functions(pattern = nil)
        api = current_api
        entries = api.functions.select do |entry|
          pattern.nil? || [api.ruby_call(entry), entry.qualified_name].any? { matches?(_1, pattern) }
        end
        puts Docs.new(api).listing(entries)
      end

      # Prints a function's documentation, or a namespace's functions.
      def doc(name)
        api = current_api
        docs = Docs.new(api)
        entry = api.lookup(name)
        puts(if entry.nil? then docs.unknown(name)
             elsif entry.namespace? then docs.namespace(entry)
             else docs.function(entry)
             end)
      end

      def inspect = "AB"
      alias to_s inspect

      private

      def matches?(text, pattern) = pattern.is_a?(Regexp) ? pattern.match?(text) : text.include?(pattern.to_s)

      def current_api
        session = Fiber[:afterburner_session] or
          raise NameError.new("`AB` needs the game's API: use it in `afterburner console` or a running script", :AB)
        session.api
      end
    end

    # Renders AB's output as text, from the API the game's definitions
    # describe.
    class Docs
      def initialize(api)
        @api = api
      end

      # One line per function: Ruby call, RAM, JavaScript name.
      def listing(entries)
        return "(no functions match)" if entries.empty?

        rows = entries.map { [@api.ruby_call(_1), gb(_1.ram), _1.qualified_name] }
        widths = (0..1).map { |column| rows.map { _1[column].size }.max }
        rows.map { |call, ram, js| "#{call.ljust(widths[0])}  #{ram.rjust(widths[1])}  #{js}" }.join("\n")
      end

      def namespace(entry)
        functions = @api.functions.select { _1.path[0, entry.path.size] == entry.path }
        "#{@api.ruby_call(entry)}: #{functions.size} functions\n\n#{listing(functions)}"
      end

      def function(entry)
        member = @api.member(entry)
        return property(entry, member) if entry.property?

        params = parameters(member.signature)
        options = params.last && @api.options(params.last[:type])
        ruby_params = params.map.with_index(1) { |param, n| ruby_param(param, options: options && n == params.size) }
        returns = member.returns.to_s.sub(/\APromise<(.*)>\z/, '\1')

        lines = ["#{@api.ruby_call(entry)}(#{ruby_params.join(', ')}) → #{returns}    #{gb(entry.ram)}"]
        lines << "  JavaScript: ns.#{entry.qualified_name.delete_suffix(member.name)}#{member.signature.delete_suffix(';')}"
        aliases = @api.ruby_names_for(entry).drop(1)
        lines << "  Also: #{aliases.join(', ')}" unless aliases.empty?
        if options
          lines << "  #{Api.underscore(params.last[:name])}, as keywords:"
          width = options.map { Api.underscore(_1.name).size + _1.type.to_s.size }.max + 2
          options.each do |field|
            label = "#{Api.underscore(field.name)}: #{field.type}"
            lines << "    #{label.ljust(width)}  #{summary(field.doc)}".rstrip
          end
        end
        body = clean(member.doc)
        body.empty? ? lines.join("\n") : "#{lines.join("\n")}\n\n#{body}"
      end

      def property(entry, member)
        body = clean(member.doc)
        header = "#{@api.ruby_call(entry)} → #{member.type}"
        body.empty? ? header : "#{header}\n\n#{body}"
      end

      def unknown(name)
        *namespaces, last = name.to_s.delete_prefix("ns.").split(".")
        namespace = namespaces.empty? ? [] : @api.lookup(namespaces.join("."))&.path
        suggestions = namespace ? @api.suggestions(namespace, last.to_s).grep_v(/[A-Z]/) : []
        message = "No function or namespace called `#{name}'."
        suggestions.empty? ? message : "#{message} Did you mean? #{suggestions.join(', ')}"
      end

      private

      def gb(ram) = ram.nil? ? "?" : "#{ram.round(2).to_s.sub(/\.0\z/, '')} GB"

      # The parameters in a signature like "hack(host?: string, opts?:
      # BasicHGWOptions): Promise<number>;", as {name:, type:, optional:, rest:}.
      def parameters(signature)
        inside = between_parens(signature.to_s) or return []
        split_top_level(inside).filter_map do |text|
          match = /\A(\.\.\.)?(\w+)(\?)?\s*:\s*(.+)\z/m.match(text.strip) or next
          { rest: !match[1].nil?, name: match[2], optional: !match[3].nil?, type: match[4].strip }
        end
      end

      # options: whether this is the trailing options object, which Ruby passes
      # as keyword arguments.
      def ruby_param(param, options:)
        name = Api.underscore(param[:name])
        return "*#{name}" if param[:rest]
        return "**#{name}" if options

        param[:optional] ? "#{name} = nil" : name
      end

      # The text inside the parameter list's parentheses.
      def between_parens(signature)
        open = signature.index("(") or return nil
        depth = 0
        (open...signature.size).each do |i|
          depth += bracket_change(signature, i)
          return signature[(open + 1)...i] if depth.zero?
        end
        nil
      end

      # Splits on commas that aren't inside brackets.
      def split_top_level(text)
        parts = [+""]
        depth = 0
        text.each_char.with_index do |char, i|
          depth += bracket_change(text, i)
          char == "," && depth.zero? ? parts << +"" : parts.last << char
        end
        parts.map(&:strip).reject(&:empty?)
      end

      def bracket_change(text, i)
        char = text[i]
        return 0 if char == ">" && i.positive? && text[i - 1] == "=" # an arrow, not a closing bracket

        if "([{<".include?(char) then 1
        elsif ")]}>".include?(char) then -1
        else 0
        end
      end

      # A JSDoc block as plain text: no comment markers, links as their text,
      # parameters under their Ruby names, and no RAM line (the header has it).
      def clean(doc)
        lines = doc.to_s.lines.map do |line|
          line.chomp.sub(%r{\A\s*/\*\*\s?}, "").sub(%r{\s*\*/\s*\z}, "").sub(/\A\s*\*(?: |\z)/, "")
        end
        lines.reject! { _1.strip.match?(/\A(?:@remarks|RAM cost: [\d.]+ GB)\z/) }
        text = lines.join("\n")
        text = text.gsub(/\{@link\s+[^}|]+?\s*\|\s*([^}]+?)\s*\}/, '\1').gsub(/\{@link\s+([^}]+?)\s*\}/) { Regexp.last_match(1).split(".").last }
        text = text.gsub(/^@param (\w+)/) { "@param #{Api.underscore(Regexp.last_match(1))}" }
        text.gsub(/\n{3,}/, "\n\n").strip
      end

      # The first paragraph of a field's doc, on one line.
      def summary(doc) = clean(doc).split(/\n\s*\n/).first.to_s.split("\n").map(&:strip).join(" ")
    end
  end
end

AB = Afterburner::AB
