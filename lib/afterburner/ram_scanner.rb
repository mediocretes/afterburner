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
  #   ns.public_send(:hack, t)     ns.send("hack", t)
  #
  # A call it can't see (a name built at runtime, ns passed through a variable
  # with another name) isn't charged, and the game kills the script when it
  # makes that call, the same as it would for a JavaScript script that
  # dodged the game's own scan.
  #
  # Only code the script can reach is charged, so a library can hold methods a
  # script never calls without the script paying for them. The code is split
  # into units: each file's load-time code (everything outside a def, which
  # runs when the file loads), each method by name, and the lambdas held as
  # plain data in each constant by name. Load-time code is reachable from the
  # start; a call to a name reaches every method of that name, in any class;
  # reading a constant reaches its lambdas. Names count as called when they're
  # called (including the reader and setter behind obj.x += 1 and a[k] ||= v),
  # passed as a literal symbol or string (send(:x), map(&:x), inject(:+)),
  # aliased, used as a compound operator, or called by Ruby itself (IMPLICIT).
  # Matching by name alone over-charges a little but never misses a method. If
  # reachable code dispatches in a way the scan can't follow (obj.send(name)
  # or map(&name) with the name in a variable, eval of a string), it charges
  # every unit, as if everything were reachable, and says why.
  class RamScanner
    Charge = Data.define(:name, :ram)
    # skipped: charges in code the script can't reach, which it doesn't pay.
    # fallback: why everything was charged anyway, or nil.
    Result = Data.define(:ram, :charges, :unknown, :files, :skipped, :fallback) do
      # "1.6 base + getServerMaxMoney 0.1 + hack 0.1"
      def breakdown
        ["#{Api::BASE_RAM} base", *charges.map { "#{_1.name} #{format_gb(_1.ram)}" }].join(" + ")
      end

      def format_gb(value) = value.round(2).to_s.sub(/\.0\z/, "")
    end

    NS_NAMES = %i[ns @ns].freeze
    SENDS = %i[send public_send __send__].freeze

    # Methods Ruby (or afterburner, or the standard library) calls without a
    # call in the source: object setup and copying; conversions (string
    # interpolation, puts, format, splats, &, File, Rational, Regexp.union);
    # iteration; comparison and hashing (sort, uniq, case/when, Set, Hash
    # keys); arithmetic coercion and the operators core methods use (sum,
    # ranges, sleep); pattern matching; exceptions (raise, error messages,
    # afterburner's own reports); Hash#default; IO-like objects (Logger,
    # $stdout); backticks; pp, JSON, YAML, Marshal; and the hooks.
    IMPLICIT = %i[
      initialize initialize_copy initialize_dup initialize_clone
      to_s inspect to_str to_ary to_a to_h to_hash to_proc to_int to_i to_f to_r to_c to_sym to_path to_regexp
      to_io to_open to_json as_json json_create encode_with init_with pretty_print instance_variables_to_inspect
      each <=> == === =~ eql? hash coerce succ call divmod + - * / % ** < > <= >= << [] []=
      deconstruct deconstruct_keys
      message detailed_message full_message backtrace exception result
      default write warn `
      method_missing respond_to_missing? respond_to?
      inherited included extended prepended method_added singleton_method_added const_missing const_added
      append_features extend_object prepend_features method_removed method_undefined singleton_method_removed
      singleton_method_undefined
      marshal_dump marshal_load _dump _load
    ].freeze

    # Calls that reach a method by a name given as the first argument.
    BY_NAME = (SENDS + %i[method public_method instance_method public_instance_method singleton_method to_enum
                         enum_for]).freeze
    # Calls that run code given as a string.
    EVALS = %i[eval instance_eval class_eval module_eval].freeze
    # Names that, passed to a BY_NAME call, dispatch again by a name or a string
    # the scan never sees: send(:public_send, name), method(:eval).
    INDIRECT = (BY_NAME + EVALS + %i[const_get alias_method define_method bind_call]).freeze
    # Calls whose literal arguments name definitions, not calls.
    DECLARATIONS = %i[
      define_method define_singleton_method attr attr_reader attr_writer attr_accessor
      private public protected private_class_method public_class_method module_function
      private_constant public_constant undef_method remove_method alias_method
    ].freeze
    # Writes through a receiver, which call a reader and a setter (obj.x += 1),
    # or [] and []= (a[k] ||= v), without a CallNode for either.
    ATTRIBUTE_WRITES = %i[CallOperatorWriteNode CallOrWriteNode CallAndWriteNode].freeze
    INDEX_WRITES = %i[IndexOperatorWriteNode IndexOrWriteNode IndexAndWriteNode].freeze

    # A stretch of code that runs together.
    Unit = Struct.new(:charges, :calls, :constants, :dynamic) do
      def self.empty = new([], Set.new, Set.new, nil)
    end

    def initialize(api)
      @api = api
    end

    def scan(path)
      units = Hash.new { |hash, key| hash[key] = Unit.empty }
      unknown = Set.new
      files = []
      queue = [File.expand_path(path)]
      until queue.empty?
        file = queue.shift
        next if files.include?(file) || !File.file?(file)

        files << file
        visitor = Visitor.new(@api, file, units)
        Prism.parse_file(file).value.accept(visitor)
        unknown.merge(visitor.unknown)
        queue.concat(visitor.requires)
      end
      reached, fallback = reach(units, files)
      charged = charges_in(reached.map { units[_1] })
      skipped = charges_in(units.values).reject { |name, _| charged.key?(name) }
      Result.new(ram: total(charged), charges: list(charged), unknown: unknown.to_a.sort, files:, skipped: list(skipped),
                 fallback:)
    end

    private

    # The keys of the units the script can reach, and, if it had to charge
    # everything, why.
    def reach(units, files)
      queue = files.map { [:load, _1] } + IMPLICIT.map { [:method, _1] }
      reached = Set.new
      until queue.empty?
        key = queue.shift
        next unless units.key?(key) && reached.add?(key)

        unit = units[key]
        return [units.keys, unit.dynamic] if unit.dynamic

        queue.concat(unit.calls.map { [:method, _1] })
        queue.concat(unit.constants.map { [:constant, _1] })
      end
      [reached.to_a, nil]
    end

    def charges_in(units)
      units.flat_map(&:charges).each_with_object({}) { |entry, found| found[entry.qualified_name] ||= entry.ram || 0.0 }
    end

    def list(charges) = charges.sort.map { |name, ram| Charge.new(name:, ram:) }
    def total(charges) = (Api::BASE_RAM + charges.values.sum).round(2)

    class Visitor < Prism::Visitor
      attr_reader :unknown, :requires

      def initialize(api, file, units)
        super()
        @api = api
        @file = file
        @units = units
        @keys = [[:load, file]]
        # The constant whose value is being read, and the lambdas in it that
        # are plain data (deferred until the constant is used).
        @constant = nil
        @deferred = Set.new.compare_by_identity
        @block_params = [] # each enclosing def's &block parameter
        @proc_variables = Set.new # local variables assigned a lambda or proc
        @unknown = []
        @requires = []
        @aliases = {} # variable name → namespace path, e.g. :hacknet → ["hacknet"]
      end

      def visit_call_node(node)
        charge(node)
        follow_require(node)
        note_call(node)
        key = if (name = defined_method(node)) then [:method, name]
              elsif @deferred.include?(node) then [:constant, @constant]
              end
        return super unless key

        # define_method(:x) { } is method x; lambda { } kept in a constant runs
        # when the constant is used.
        node.receiver&.accept(self)
        node.arguments&.accept(self)
        within(key) { node.block.accept(self) }
      end

      def visit_def_node(node)
        @block_params.push(node.parameters&.block&.name)
        within([:method, node.name]) { reading_constant(nil, nil) { super } }
      ensure
        @block_params.pop
      end

      def visit_lambda_node(node)
        return super unless @deferred.include?(node)

        within([:constant, @constant]) { super }
      end

      # A constant's value is read when the file loads; lambdas kept in it as
      # plain data run when the constant is used.
      def visit_constant_write_node(node) = constant_value(node.name, node.value) { super }
      def visit_constant_or_write_node(node) = constant_value(node.name, node.value) { super }
      def visit_constant_path_write_node(node) = constant_value(constant_name(node.target), node.value) { super }
      def visit_constant_path_or_write_node(node) = constant_value(constant_name(node.target), node.value) { super }

      def visit_constant_read_node(node)
        unit.constants << node.name
        super
      end

      def visit_constant_path_node(node)
        unit.constants << constant_name(node)
        super
      end

      # map(&:name) calls name. A block argument the scan can't see into (a
      # name in a variable, a hash lookup) could call anything.
      def visit_block_argument_node(node)
        expression = node.expression
        if (name = literal_name(expression)) then unit.calls << name
        elsif !(expression.nil? || known_proc?(expression)) then dynamic!(node, "a block argument (&) the scan can't follow")
        end
        super
      end

      def visit_alias_method_node(node)
        (name = literal_name(node.old_name)) && unit.calls << name
        super
      end

      def visit_local_variable_write_node(node)
        @proc_variables << node.name if proc_literal?(node.value)
        remember_alias(node) && super
      end

      # hacknet = ns.hacknet (or @hacknet = ns.hacknet) makes hacknet.x count.
      def visit_instance_variable_write_node(node) = remember_alias(node) && super

      # `cmd` calls the ` method.
      def visit_x_string_node(node) = (unit.calls << :`) && super
      def visit_interpolated_x_string_node(node) = (unit.calls << :`) && super

      def self.snake(type) = type.to_s.gsub(/(?<!^)([A-Z])/, '_\1').downcase

      # x += 1 calls +; obj.x += 1 also calls x and x=; a[k] += 1 calls [] and []=.
      # (Constant ||= is handled above, as a constant's value.)
      (Prism.constants.grep(/(Operator|Or|And)WriteNode\z/) - %i[ConstantOrWriteNode ConstantPathOrWriteNode]).each do |type|
        define_method(:"visit_#{snake(type)}") do |node|
          unit.calls << node.binary_operator if node.respond_to?(:binary_operator)
          unit.calls.merge([node.read_name, node.write_name]) if ATTRIBUTE_WRITES.include?(type)
          unit.calls.merge(%i[[] []=]) if INDEX_WRITES.include?(type)
          super(node)
        end
      end

      # a.b, c[1] = 1, 2 and `for a.b in ...` call b= and []=.
      def visit_call_target_node(node) = (unit.calls << node.name) && super
      def visit_index_target_node(node) = (unit.calls << :[]=) && super

      private

      def unit = @units[@keys.last]

      def within(key)
        @keys.push(key)
        yield
      ensure
        @keys.pop
      end

      def constant_value(name, value, &)
        reading_constant(name, plain_data_procs(value), &)
        # A = B = ->{ } keeps the lambda under B; reading A reaches it too.
        inner_constants(value).each { @units[[:constant, name]].constants << _1 }
      end

      def reading_constant(name, deferred)
        outer = [@constant, @deferred]
        @constant = name
        @deferred = deferred || Set.new.compare_by_identity
        yield
      ensure
        @constant, @deferred = outer
      end

      # The lambdas and procs in a constant's value that are plain data: the
      # value itself, or inside arrays and hashes of it, perhaps frozen. One
      # that's called, or passed to something, while the value is built runs
      # then, so it stays with the code around it.
      def plain_data_procs(node, found = Set.new.compare_by_identity)
        case node
        when Prism::LambdaNode then found << node
        when Prism::CallNode
          if proc_literal?(node) then found << node
          elsif node.name == :freeze && node.arguments.nil? && node.block.nil? then plain_data_procs(node.receiver, found)
          end
        when Prism::ArrayNode, Prism::HashNode, Prism::KeywordHashNode then node.elements.each { plain_data_procs(_1, found) }
        when Prism::AssocNode then plain_data_procs(node.value, found)
        when Prism::ParenthesesNode then plain_data_procs(node.body, found)
        when Prism::StatementsNode then plain_data_procs(node.body.last, found)
        end
        found
      end

      def inner_constants(node)
        case node
        when Prism::ConstantWriteNode, Prism::ConstantOrWriteNode then [node.name]
        when Prism::ConstantPathWriteNode, Prism::ConstantPathOrWriteNode then [constant_name(node.target)]
        else []
        end
      end

      def constant_name(node) = node.respond_to?(:name) ? node.name : node.full_name.split("::").last.to_sym

      # lambda { }, proc { }, or Proc.new { }.
      def proc_literal?(node)
        return true if node.is_a?(Prism::LambdaNode)
        return false unless node.is_a?(Prism::CallNode) && node.block.is_a?(Prism::BlockNode)

        (%i[lambda proc].include?(node.name) && node.receiver.nil?) ||
          (node.name == :new && node.receiver.is_a?(Prism::ConstantReadNode) && node.receiver.name == :Proc)
      end

      # A block argument whose code the scan sees: a lambda or proc literal,
      # method(:name), a variable holding a lambda, or the method's own &block.
      def known_proc?(node)
        return true if proc_literal?(node)
        return method_by_literal?(node) if node.is_a?(Prism::CallNode)
        return false unless node.is_a?(Prism::LocalVariableReadNode)

        @proc_variables.include?(node.name) || node.name == @block_params.last
      end

      def method_by_literal?(node)
        %i[method public_method].include?(node.name) && literal_name(node.arguments&.arguments&.first)
      end

      # The method define_method(:literal) { } defines, or nil. With a name
      # in a variable, the block stays in the code around it, which is charged
      # whenever that code is.
      def defined_method(node)
        return unless node.name == :define_method && node.block.is_a?(Prism::BlockNode)

        literal_name(node.arguments&.arguments&.first)
      end

      # Every call names a method, and literal names passed along may too
      # (send(:x), inject(:+), method(:x)). A name the scan can't read, sent
      # to anything but ns, could be any method; so could code in a string.
      def note_call(node)
        unit.calls << node.name
        arguments = node.arguments&.arguments || []
        literal_arguments(node, arguments).each { |argument| (name = literal_name(argument)) && unit.calls << name }
        first = literal_name(arguments.first)
        if BY_NAME.include?(node.name) && arguments.any? && !ns_rooted?(node.receiver)
          if !first then dynamic!(node, "#{node.name} with a name the scan can't read")
          elsif INDIRECT.include?(first) then dynamic!(node, "#{node.name}(:#{first}), which dispatches again")
          end
        elsif node.name == :eval ? !node.block : (EVALS.include?(node.name) && arguments.any? && !node.block)
          dynamic!(node, "#{node.name} of a string")
        elsif node.name == :const_get
          if (path = first) then unit.constants.merge(path.to_s.split("::").reject(&:empty?).map(&:to_sym))
          else dynamic!(node, "const_get with a name the scan can't read")
          end
        elsif node.name == :alias_method && !literal_name(arguments[1])
          dynamic!(node, "alias_method with a name the scan can't read")
        elsif %i[inject reduce].include?(node.name) && !node.block && arguments.any? && !literal_name(arguments.last)
          dynamic!(node, "#{node.name} with an operator the scan can't read")
        elsif node.name == :to_proc && node.receiver
          receiver = node.receiver
          if (name = literal_name(receiver)) then unit.calls << name
          elsif !known_proc?(receiver) then dynamic!(node, "to_proc on something the scan can't follow")
          end
        end
      end

      # The arguments whose literal names count as calls: not those naming
      # definitions, and for alias_method only the old name.
      def literal_arguments(node, arguments)
        if node.name == :alias_method then arguments.drop(1)
        elsif DECLARATIONS.include?(node.name) then []
        else arguments
        end
      end

      def dynamic!(node, why)
        unit.dynamic ||= "#{why} (#{File.basename(@file)}:#{node.location.start_line})"
      end

      def literal_name(node)
        case node
        when Prism::SymbolNode, Prism::StringNode then node.unescaped.to_sym
        end
      end

      def ns_rooted?(node)
        return false unless node

        _names, root = chain(node)
        !root_path(root).nil?
      end

      def charge(node)
        names, root = chain(node)
        path = root_path(root) or return
        resolved = resolve(path, names) or return
        unit.charges << resolved if resolved.function?
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

      # ns.hacknet.num_nodes → [["hacknet", "num_nodes"], <ns node>]. A send
      # with a literal name stands for that name, wherever it is in the chain:
      # ns.send(:hacknet).public_send("num_nodes") is ns.hacknet.num_nodes.
      def chain(node)
        names = []
        while node.is_a?(Prism::CallNode) && node.receiver
          sent = SENDS.include?(node.name) && literal_name(node.arguments&.arguments&.first)
          names.unshift((sent || node.name).to_s)
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
