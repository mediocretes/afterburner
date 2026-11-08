# frozen_string_literal: true

require "find"

module Afterburner
  # Keeps the game's home server in step with a folder on disk, the job
  # bitburner-filesync does: pushes every file when the game connects, then
  # each change. Deletes too, if allowed. Polls rather than using OS file
  # events, so it works the same everywhere; excluded folders (node_modules
  # among them) aren't even walked.
  class FileSync
    def initialize(root:, extensions:, exclude:, allow_deleting:, log:)
      @root = root
      @extensions = extensions
      @exclude = exclude
      @allow_deleting = allow_deleting
      @log = log
      @state = {}
    end

    # Synced files under the root: relative name → [mtime, size].
    def files
      return {} unless File.directory?(@root)

      found = {}
      Find.find(@root) do |path|
        name = path.delete_prefix(@root).delete_prefix("/")
        next if name.empty?

        if File.directory?(path)
          Find.prune if excluded?(name)
        elsif @extensions.include?(File.extname(name)) && !excluded?(name)
          found[name] = [File.mtime(path).to_f, File.size(path)]
        end
      rescue SystemCallError
        next # removed while we looked
      end
      found
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

    def excluded?(name)
      parts = name.split("/")
      @exclude.any? do |pattern|
        # "dir/sub" matches that path; a bare name like "node_modules" matches at any depth.
        name == pattern || name.start_with?("#{pattern}/") || (!pattern.include?("/") && parts.include?(pattern))
      end
    end
  end
end
