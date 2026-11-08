# frozen_string_literal: true

module Afterburner
  # The .rb scripts under src/. Files under any lib/ directory are libraries
  # for scripts to require_relative; they don't get stubs and can't be run.
  class Scripts
    NAME = %r{\A(?:[\w.-]+/)*[\w.-]+\.rb\z}

    attr_reader :root

    def initialize(root)
      @root = File.directory?(root) ? File.realpath(root) : File.expand_path(root)
    end

    def entries = all_names.reject { library?(_1) }

    # Every .rb file, libraries included, as full paths.
    def all_files = all_names.map { File.join(@root, _1) }

    def library?(name) = name.split("/")[0...-1].include?("lib")

    # The full path to run for a script name the game sent. Only plain
    # relative names of entry scripts inside src/ get through.
    def resolve(name)
      unless name.is_a?(String) && NAME.match?(name) && !name.split("/").include?("..")
        raise ScriptNotFound, "#{name.inspect} isn't a script name afterburner will run"
      end
      raise ScriptNotFound, "#{name} is a library (it's under lib/), not a script" if library?(name)

      path = File.join(@root, name)
      raise ScriptNotFound, "There's no #{name} in #{@root}" unless File.file?(path)

      real = File.realpath(path)
      raise ScriptNotFound, "#{name} points outside #{@root}" unless real.start_with?("#{@root}/")

      real
    end

    private

    def all_names = File.directory?(@root) ? Dir.glob("**/*.rb", base: @root).sort : []
  end
end
