# frozen_string_literal: true

require_relative "test_helper"

class FileSyncTest < Minitest::Test
  def setup
    @dir = Dir.mktmpdir
    @link = RecordingLink.new
  end

  def teardown = FileUtils.remove_entry(@dir)

  def write(name, text)
    path = File.join(@dir, name)
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, text)
    File.utime(Time.now + rand(1000), Time.now + rand(1000), path) # a distinct mtime even within one clock tick
  end

  def sync(allow_deleting: false)
    Afterburner::FileSync.new(root: @dir, extensions: %w[.js .txt], exclude: [".vscode"], allow_deleting:, log: quiet_log)
  end

  def test_pushes_everything_on_connect
    write("a.js", "a")
    write("lib/b.js", "b")
    write("notes.txt", "n")
    write("skip.md", "x")
    write(".vscode/c.js", "c")
    sync.push_all(@link)
    assert_equal({ "a.js" => "a", "lib/b.js" => "b", "notes.txt" => "n" }, @link.pushed)
  end

  def test_pushes_changes_after_that
    write("a.js", "a")
    files = sync
    files.push_all(@link)
    @link.pushed.clear
    files.tick(@link)
    assert_empty @link.pushed
    write("a.js", "a2")
    write("new.js", "n")
    files.tick(@link)
    assert_equal({ "a.js" => "a2", "new.js" => "n" }, @link.pushed)
  end

  def test_deletes_only_when_allowed
    write("a.js", "a")
    [false, true].each do |allowed|
      write("a.js", "a")
      files = sync(allow_deleting: allowed)
      files.push_all(@link)
      File.delete(File.join(@dir, "a.js"))
      files.tick(@link)
    end
    assert_equal ["a.js"], @link.deleted
  end

  def test_keeps_track_while_the_game_is_away
    write("a.js", "a")
    files = sync
    files.tick(nil)
    assert_empty @link.pushed
  end
end
