# frozen_string_literal: true

require_relative "test_helper"

class SourceBackupTest < Minitest::Test
  def setup
    @dir = Dir.mktmpdir
    @src = File.join(@dir, "src")
    FileUtils.mkdir_p(@src)
    @log = StringIO.new
  end

  def teardown = FileUtils.remove_entry(@dir)

  def write(name, text, mtime: Time.now)
    path = File.join(@src, name)
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, text)
    File.utime(mtime, mtime, path)
  end

  def backup = Afterburner::SourceBackup.new(scripts: Afterburner::Scripts.new(@src), log: quiet_log(@log))
  def saved(name, content, mtime) = { "filename" => "afterburner/src/#{name}.txt", "content" => content, "mtime" => (mtime.to_f * 1000).to_i }
  def copy(name, content, mtime) = Afterburner::SourceBackup::Saved.new(name:, content:, mtime: (mtime.to_f * 1000).to_i)

  def test_names
    assert_equal "afterburner/src/lib/x.rb.txt", Afterburner::SourceBackup.game_name("lib/x.rb")
    assert_equal "lib/x.rb", Afterburner::SourceBackup.saved_name("/afterburner/src/lib/x.rb.txt")
    assert_nil Afterburner::SourceBackup.saved_name("afterburner/proxy.js")
    assert_nil Afterburner::SourceBackup.saved_name("afterburner/src/notes.txt")
  end

  def test_copies_every_script_libraries_included
    write("hello.rb", "puts 1")
    write("lib/util.rb", "X = 1")
    link = RecordingLink.new
    backup.push_all(link)
    assert_equal({ "afterburner/src/hello.rb.txt" => "puts 1", "afterburner/src/lib/util.rb.txt" => "X = 1" }, link.pushed)
  end

  def test_leaves_a_newer_copy_in_the_save_alone
    write("hello.rb", "old", mtime: Time.now - 600)
    link = RecordingLink.new(files: [saved("hello.rb", "newer, from the other machine", Time.now)])
    backup.push_all(link)
    assert_empty link.pushed
    assert_includes @log.string, "the save's copy of hello.rb is newer than src/hello.rb"
  end

  def test_replaces_an_older_copy
    write("hello.rb", "new")
    link = RecordingLink.new(files: [saved("hello.rb", "old", Time.now - 600)])
    backup.push_all(link)
    assert_equal "new", link.pushed["afterburner/src/hello.rb.txt"]
  end

  def test_skips_an_identical_copy
    write("hello.rb", "same", mtime: Time.now - 600)
    link = RecordingLink.new(files: [saved("hello.rb", "same", Time.now)])
    backup.push_all(link)
    assert_empty link.pushed
  end

  def test_mentions_what_only_the_save_has
    link = RecordingLink.new(files: [saved("a.rb", "1", Time.now), saved("b.rb", "2", Time.now)])
    backup.push_all(link)
    assert_includes @log.string, "the save holds 2 Ruby files that src/ doesn't (a.rb, b.rb)"
    assert_empty link.deleted
  end

  def test_tick_pushes_edits_and_deletes_only_what_it_put_there
    write("hello.rb", "v1", mtime: Time.now - 60)
    link = RecordingLink.new(files: [saved("elsewhere.rb", "x", Time.now)])
    b = backup
    b.push_all(link)
    write("hello.rb", "v2")
    b.tick(link)
    assert_equal "v2", link.pushed["afterburner/src/hello.rb.txt"]
    File.delete(File.join(@src, "hello.rb"))
    b.tick(link)
    assert_equal ["afterburner/src/hello.rb.txt"], link.deleted
  end

  def test_restore_plan
    write("same.rb", "same")
    write("mine.rb", "mine, newer")
    write("stale.rb", "stale", mtime: Time.now - 600)
    saved = [copy("new.rb", "brand new", Time.now), copy("same.rb", "same", Time.now),
             copy("mine.rb", "theirs", Time.now - 600), copy("stale.rb", "fresh", Time.now),
             copy("../escape.rb", "nope", Time.now), copy("lib/../../x.rb", "nope", Time.now)]
    plan = Afterburner::SourceRestore.new(root: @src, saved:).plan.to_h { [_1.name, _1.action] }
    assert_equal({ "new.rb" => :write, "same.rb" => :skip, "mine.rb" => :keep, "stale.rb" => :write,
                   "../escape.rb" => :refuse, "lib/../../x.rb" => :refuse }, plan)
  end

  def test_restore_writes_and_backs_up_what_it_replaces
    write("mine.rb", "mine, newer")
    saved = [copy("lib/new.rb", "brand new", Time.now), copy("mine.rb", "theirs", Time.now - 600)]
    restore = Afterburner::SourceRestore.new(root: @src, saved:, force: true, now: Time.at(0))
    steps = restore.run
    assert_equal %i[write replace], steps.map(&:action)
    assert_equal "brand new", File.read(File.join(@src, "lib/new.rb"))
    assert_equal "theirs", File.read(File.join(@src, "mine.rb"))
    assert_equal "mine, newer", File.read(File.join(restore.backup_dir, "mine.rb"))
    refute File.exist?(File.join(@dir, "escape.rb"))
  end
end
