# frozen_string_literal: true

require "fileutils"

module Afterburner
  # Copies of the Ruby scripts, kept in the game's save so the code travels
  # with it: Steam Cloud, an export, another machine. The game stores only
  # scripts and text files, so src/hello.rb is kept as
  # afterburner/src/hello.rb.txt.
  #
  # Writing into the save is automatic. Reading code back out never is: any
  # script in the game can write files there, so code from the save reaches
  # your src/ only through `afterburner restore` (SourceRestore), which says
  # what it's doing.
  #
  # A copy in the save that's newer than the local file (edited on another
  # machine, say) is left alone, not overwritten with the older local one.
  class SourceBackup
    FOLDER = "afterburner/src/"
    # Seconds of clock difference between machines to ignore.
    SLACK = 2.0

    Saved = Data.define(:name, :content, :mtime) # name: relative, as in src/

    def self.game_name(name) = "#{FOLDER}#{name}.txt"

    def self.saved_name(game_name)
      game_name = game_name.delete_prefix("/")
      game_name.delete_prefix(FOLDER).delete_suffix(".txt") if game_name.start_with?(FOLDER) && game_name.end_with?(".rb.txt")
    end

    def initialize(scripts:, log:)
      @scripts = scripts
      @log = log
      @seen = {}   # name → mtime, as of the last look
      @pushed = {} # name → content in the save, as far as we know
    end

    # The copies in the save, with their modification times where the game
    # reports them.
    def self.saved(link)
      mtimes = begin
        link.all_file_metadata.to_h { [_1["filename"].delete_prefix("/"), _1["mtime"]] }
      rescue GameLink::Error
        {} # an older game; content comparison still works
      end
      link.all_files.filter_map do |file|
        name = saved_name(file["filename"]) or next
        Saved.new(name:, content: file["content"], mtime: mtimes[file["filename"].delete_prefix("/")])
      end
    end

    # On connect: copy every script in, except where the save's copy is newer,
    # and say what the save has that src/ doesn't.
    def push_all(link)
      saved = SourceBackup.saved(link).to_h { [_1.name, _1] }
      local = local_files
      @seen = local.transform_values(&:last)
      @pushed = {}
      local.each do |name, (content, mtime)|
        copy = saved[name]
        if copy&.content == content
          @pushed[name] = content
        elsif copy&.mtime && copy.mtime / 1000.0 > mtime + SLACK
          @pushed[name] = copy.content
          @log.warn("the save's copy of #{name} is newer than src/#{name}, so it's staying. " \
                    "`afterburner restore` takes it; saving src/#{name} again pushes yours.")
        else
          push(link, name, content)
        end
      end
      only_saved = saved.keys - local.keys
      return if only_saved.empty?

      shown = only_saved.first(3).join(", ") + (only_saved.size > 3 ? ", ..." : "")
      @log.info("the save holds #{only_saved.size} Ruby file#{'s' unless only_saved.size == 1} that src/ doesn't " \
                "(#{shown}); `afterburner restore` brings them here")
    end

    # Pushes scripts edited since the last look; deletes the copies of ones
    # deleted here (only those this session put there).
    def tick(link)
      stamps = local_stamps
      changed = stamps.reject { |name, mtime| @seen[name] == mtime }.keys
      removed = @seen.keys - stamps.keys
      @seen = stamps
      return unless link

      changed.each do |name|
        content = read(name)
        push(link, name, content) unless @pushed[name] == content
      end
      removed.each do |name|
        next unless @pushed.delete(name)

        link.delete_file(SourceBackup.game_name(name))
        @log.info("deleted the save's copy of #{name}")
      end
    rescue GameLink::Error => e
      @log.warn(e.message)
    end

    private

    def push(link, name, content)
      link.push_file(SourceBackup.game_name(name), content)
      @pushed[name] = content
    end

    def local_stamps
      @scripts.all_files.to_h { [_1.delete_prefix("#{@scripts.root}/"), File.mtime(_1).to_f] }
    rescue SystemCallError
      {}
    end

    def local_files = local_stamps.to_h { |name, mtime| [name, [read(name), mtime]] }

    def read(name) = File.read(File.join(@scripts.root, name), encoding: Encoding::UTF_8).scrub
  end

  # `afterburner restore`: writes the save's copies of Ruby scripts into
  # src/. Adds what's missing, updates what the save has newer, and keeps
  # newer local files unless forced (and then backs them up first). Names
  # that would land outside src/ are refused.
  class SourceRestore
    Step = Data.define(:name, :action, :reason)

    def initialize(root:, saved:, force: false, now: Time.now)
      @root = File.expand_path(root)
      @saved = saved
      @force = force
      @now = now
    end

    def plan
      @saved.sort_by(&:name).map do |copy|
        next Step.new(copy.name, :refuse, "not a plain script name inside src/") unless safe?(copy.name)

        path = File.join(@root, copy.name)
        if !File.exist?(path)
          Step.new(copy.name, :write, "new")
        elsif File.read(path, encoding: Encoding::UTF_8) == copy.content
          Step.new(copy.name, :skip, "already the same")
        elsif copy.mtime && copy.mtime / 1000.0 > File.mtime(path).to_f + SourceBackup::SLACK
          Step.new(copy.name, :write, "the save's copy is newer")
        elsif @force
          Step.new(copy.name, :replace, "yours is newer, but --force; yours is backed up")
        else
          Step.new(copy.name, :keep, "yours is newer; --force takes the save's")
        end
      end
    end

    # Carries out the plan; returns it.
    def run
      steps = plan
      steps.each do |step|
        next unless %i[write replace].include?(step.action)

        path = File.join(@root, step.name)
        back_up(path) if step.action == :replace
        FileUtils.mkdir_p(File.dirname(path))
        File.write(path, @saved.find { _1.name == step.name }.content)
      end
      steps
    end

    def backup_dir = File.join(File.dirname(@root), ".afterburner", "replaced", @now.strftime("%Y%m%d-%H%M%S"))

    private

    def safe?(name)
      Scripts::NAME.match?(name) && !name.split("/").include?("..") &&
        File.expand_path(name, @root).start_with?("#{@root}/")
    end

    def back_up(path)
      target = File.join(backup_dir, path.delete_prefix("#{@root}/"))
      FileUtils.mkdir_p(File.dirname(target))
      FileUtils.cp(path, target)
    end
  end
end
