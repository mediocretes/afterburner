# frozen_string_literal: true

module Afterburner
  # Keeps the game's home server in step with a folder on disk, the job
  # bitburner-filesync does: pushes every file when the game connects, then
  # each change. Deletes too, if allowed. Polls rather than using OS file
  # events, so it works the same everywhere.
  class FileSync
    def initialize(root:, extensions:, exclude:, allow_deleting:, log:)
      @root = root
      @extensions = extensions
      @exclude = exclude
      @allow_deleting = allow_deleting
      @log = log
      @state = {}
    end

    def files
      return {} unless File.directory?(@root)

      Dir.glob("**/*", base: @root).each_with_object({}) do |name, found|
        next if excluded?(name) || !@extensions.include?(File.extname(name))

        path = File.join(@root, name)
        found[name] = [File.mtime(path).to_f, File.size(path)] if File.file?(path)
      end
    end

    def push_all(link)
      @state = files
      @state.each_key { push(link, _1) }
      @log.info("pushed #{@state.size} file#{'s' unless @state.size == 1} from #{@root}") unless @state.empty?
    end

    # Pushes what changed since the last look. Without a link it just keeps
    # track; the next connection pushes everything anyway.
    def tick(link)
      current = files
      changed = current.reject { |name, stamp| @state[name] == stamp }.keys
      removed = @state.keys - current.keys
      @state = current
      return unless link

      changed.each do |name|
        push(link, name)
        @log.info("#{name} changed")
      end
      return unless @allow_deleting

      removed.each do |name|
        link.delete_file(name)
        @log.info("#{name} deleted")
      end
    rescue GameLink::Error => e
      @log.warn(e.message)
    end

    private

    def push(link, name) = link.push_file(name, File.read(File.join(@root, name)))

    def excluded?(name) = @exclude.any? { name == _1 || name.start_with?("#{_1}/") }
  end
end
