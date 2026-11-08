# frozen_string_literal: true

require_relative "test_helper"

class AutostartTest < Minitest::Test
  def setup
    @dir = Dir.mktmpdir
    @project = File.join(@dir, "my scripts")
    FileUtils.mkdir_p(@project)
    File.write(File.join(@project, "Gemfile"), %(gem "afterburner"\n))
    @calls = []
    @out = StringIO.new
  end

  def teardown = FileUtils.remove_entry(@dir)

  def runner = ->(*command) { @calls << command and true }

  def free_port
    server = TCPServer.new("localhost", 0)
    server.addr[1].tap { server.close }
  end

  def mac(port: free_port) = Afterburner::Autostart::MacOS.new(project: @project, port:, out: @out, runner:, home: @dir, uid: 501)
  def windows(port: free_port) = Afterburner::Autostart::Windows.new(project: @project, port:, out: @out, runner:, startup: File.join(@dir, "Startup"))

  def test_macos_installs_a_launch_agent_and_starts_it
    autostart = mac
    autostart.on
    plist = File.read(autostart.plist_path)
    assert_equal File.join(@dir, "Library/LaunchAgents/io.github.mediocretes.afterburner.my-scripts.plist"), autostart.plist_path
    assert_includes plist, "<string>#{RbConfig.ruby}</string>"
    assert_includes plist, "<string>watch</string>"
    assert_includes plist, "<key>WorkingDirectory</key>\n  <string>#{@project}</string>"
    assert_includes plist, "<string>en_US.UTF-8</string>"
    assert_equal [%w[launchctl bootout gui/501/io.github.mediocretes.afterburner.my-scripts],
                  ["launchctl", "bootstrap", "gui/501", autostart.plist_path]], @calls
    assert_includes @out.string, "starting now"
    if system("which plutil", out: File::NULL)
      assert system("plutil", "-lint", autostart.plist_path, out: File::NULL), "plutil rejects the plist"
    end
  end

  def test_macos_off_stops_and_removes_it
    autostart = mac
    autostart.on
    @calls.clear
    autostart.off
    refute File.exist?(autostart.plist_path)
    assert_equal [%w[launchctl bootout gui/501/io.github.mediocretes.afterburner.my-scripts]], @calls
    assert_includes @out.string, "won't start at login any more"
  end

  def test_windows_writes_a_startup_script_and_starts_it
    autostart = windows
    autostart.on
    script = File.binread(autostart.script_path)
    assert_equal File.join(@dir, "Startup", "afterburner (my scripts).cmd"), autostart.script_path
    assert_includes script, "\r\n", "a .cmd wants CRLF"
    assert_includes script, %(cd /d "#{@project.tr('/', '\\')}")
    assert_includes script, %(start "afterburner - my scripts" /min "#{RbConfig.ruby.tr('/', '\\')}")
    assert_includes script, %("exec" "afterburner" "watch")
    assert_equal [["cmd.exe", "/c", autostart.script_path]], @calls
  end

  def test_windows_doesnt_start_a_second_one_when_the_port_is_busy
    server = TCPServer.new("localhost", 0)
    windows(port: server.addr[1]).on
    assert_empty @calls
    assert_includes @out.string, "already in use"
  ensure
    server&.close
  end

  def test_windows_off_removes_the_script
    autostart = windows
    autostart.on
    autostart.off
    refute File.exist?(autostart.script_path)
  end

  def test_refuses_a_folder_that_isnt_an_afterburner_project
    File.delete(File.join(@project, "Gemfile"))
    error = assert_raises(Afterburner::Autostart::Error) { mac.on }
    assert_includes error.message, "no Gemfile"
    File.write(File.join(@project, "Gemfile"), %(gem "rails"\n))
    assert_includes assert_raises(Afterburner::Autostart::Error) { windows.on }.message, "doesn't mention afterburner"
  end

  def test_status
    autostart = mac
    autostart.status
    assert_includes @out.string, "doesn't start at login"
    autostart.on
    autostart.status
    assert_includes @out.string, "afterburner starts at login for #{@project}"
  end
end
