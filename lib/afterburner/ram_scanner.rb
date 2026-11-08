# frozen_string_literal: true

require "prism"
require "set"

module Afterburner
  # Works out how much RAM a Ruby script needs, the way the game does for
  # JavaScript: 1.6 GB, plus the cost of each distinct Netscript function the
  # code mentions. Follows require_relative into other files.
  #
  # It counts calls written against ns:
  #
  #   ns.hack(t)                   ns.hacknet.num_nodes
  #   @ns.hack(t)                  hacknet = ns.hacknet; hacknet.num_nodes
  #   ns.public_send(:hack, t)
  #
  # A call it can't see (a name built at runtime, ns passed through a variable
  # with another name) isn't charged, and the game kills the script when it
  # makes that call, the same as it would for a JavaScript script that
  # dodged the game's own scan.
  class RamScanner
    Charge = Data.define(:name, :ram)
    Result = Data.define(:ram, :charges, :unknown, :files) do
      # "1.6 base + getServerMaxMoney 0.1 + hack 0.1"
      def breakdown
        ["#{Api::BASE_RAM} base", *charges.map { "#{_1.name} #{format_gb(_1.ram)}" }].join(" + ")
      end

      def format_gb(value) = value.round(2).to_s.sub(/\.0\z/, "")
    end

    NS_NAMES = %i[ns @ns].freeze
    SENDS = %i[send public_send __send__].freeze

    def initialize(api)
      @api = api
    end

    def scan(path)
      charges = {}
      unknown = Set.new
      files = []
      queue = [File.expand_path(path)]
      until queue.empty?
        file = queue.shift
        next if files.include?(file) || !File.file?(file)

        files << file
        visitor = Visitor.new(@api, file)
        Prism.parse_file(file).value.accept(visitor)
        visitor.charges.each { |entry| charges[entry.qualified_name] ||= entry.ram || 0.0 }
        unknown.merge(visitor.unknown)
        queue.concat(visitor.requires)
      end
      list = charges.sort.map { |name, ram| Charge.new(name:, ram:) }
      total = (Api::BASE_RAM + list.sum(&:ram)).round(2)
      Result.new(ram: total, charges: list, unknown: unknown.to_a.sort, files:)
    end

    class Visitor < Prism::Visitor
      attr_reader :charges, :unknown, :requires

      def initialize(api, file)
        super()
        @api = api
        @file = file
        @charges = []
        @unknown = []
        @requires = []
        @aliases = {} # variable name → namespace path, e.g. :hacknet → ["hacknet"]
      end

      def visit_call_node(node)
        charge(node)
        follow_require(node)
        super
      end

      # hacknet = ns.hacknet (or @hacknet = ns.hacknet) makes hacknet.x count.
      def visit_local_variable_write_node(node) = remember_alias(node) && super
      def visit_instance_variable_write_node(node) = remember_alias(node) && super

      private

      def charge(node)
        names, root = chain(node)
        path = root_path(root) or return
        names = names.dup
        if SENDS.include?(names.last&.to_sym) && (symbol = node.arguments&.arguments&.first).is_a?(Prism::SymbolNode)
          names[-1] = symbol.unescaped
        end
        resolved = resolve(path, names) or return
        @charges << resolved if resolved.function?
      end

      # Walks names left to right from the root; returns the entry for the
      # last name if everything before it is a namespace.
      def resolve(path, names)
        names.each_with_index do |name, index|
          entry = @api.resolve(path, name)
          unless entry
            @unknown << ["ns", *path, name].join(".") unless SENDS.include?(name.to_sym)
            return nil
          end
          return (index == names.size - 1 ? entry : nil) unless entry.namespace?

          path = entry.path
        end
        nil
      end

      # ns.hacknet.num_nodes → [["hacknet", "num_nodes"], <ns node>]
      def chain(node)
        names = []
        while node.is_a?(Prism::CallNode) && node.receiver
          names.unshift(node.name.to_s)
          node = node.receiver
        end
        [names, node]
      end

      def root_path(node)
        name = case node
               when Prism::LocalVariableReadNode, Prism::InstanceVariableReadNode then node.name
               when Prism::CallNode then node.name if node.receiver.nil? && node.arguments.nil?
               end
        return [] if NS_NAMES.include?(name)

        @aliases[name]
      end

      def remember_alias(node)
        names, root = chain(node.value)
        path = root_path(root)
        target = path && (names.empty? ? path : resolve_namespace(path, names))
        @aliases[node.name] = target if target
        true
      end

      def resolve_namespace(path, names)
        names.each do |name|
          entry = @api.resolve(path, name)
          return nil unless entry&.namespace?

          path = entry.path
        end
        path
      end

      def follow_require(node)
        return unless node.name == :require_relative && node.receiver.nil?

        argument = node.arguments&.arguments&.first
        return unless argument.is_a?(Prism::StringNode)

        target = File.expand_path(argument.unescaped, File.dirname(@file))
        @requires << (target.end_with?(".rb") ? target : "#{target}.rb")
      end
    end
  end
end
