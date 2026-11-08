# frozen_string_literal: true

require "fileutils"
require "rbconfig"
require "socket"

module Afterburner
  # `afterburner autostart on|off`, and plain `afterburner autostart` for
  # status: starts `afterburner watch` for this project whenever you log in, so
  # it's already running when the game restarts your Ruby scripts. Run it in
  # the project, the folder with your Gemfile.
  #
  # macOS: a launchd agent, running in the background, logging to
  # .afterburner/afterburner.log. Windows: a script in your Startup folder that
  # opens afterburner in a minimized window; close the window to stop it.
  # Neither needs admin rights.
  class Autostart
    class Error < StandardError; end

    def self.for_this_computer(**options)
      case RbConfig::CONFIG["host_os"]
      when /darwin/ then MacOS.new(**options)
      when /mswin|mingw|cygwin/ then Windows.new(**options)
      else raise Error, "autostart knows macOS and Windows; on this system, start `afterburner watch` however you like to start things"
      end
    end

    attr_reader :project

    # runner: how commands are run (tests swap it out).
    def initialize(project:, port:, out:, runner: ->(*command) { system(*command, out: File::NULL, err: File::NULL) })
      @project = File.expand_path(project)
      @port = port
      @out = out
      @runner = runner
    end

    def name = File.basename(@project)

    # What runs at login. Absolute paths, because login items don't get your
    # shell's PATH (or a version manager's shims).
    def command = [RbConfig.ruby, File.join(Gem.bindir, "bundle"), "exec", "afterburner", "watch"]

    def status
      @out.puts(installed? ? "afterburner starts at login for #{@project} (#{where})." : "afterburner doesn't start at login for #{@project}.")
      @out.puts(running? ? "Something is serving port #{@port} right now." : "Nothing is serving port #{@port} right now.")
    end

    private

    def check_project!
      gemfile = File.join(@project, "Gemfile")
      unless File.exist?(gemfile)
        raise Error, "There's no Gemfile in #{@project}. Run this in your scripts project, the folder whose Gemfile has afterburner in it."
      end
      return if Afterburner.read_text(gemfile).include?("afterburner")

      raise Error, "#{gemfile} doesn't mention afterburner; add `gem \"afterburner\"` to it first."
    end

    def running?
      TCPSocket.new("localhost", @port).close
      true
    rescue SystemCallError
      false
    end

    # launchd on macOS.
    class MacOS < Autostart
      def initialize(home: Dir.home, uid: Process.uid, **options)
        super(**options)
        @home = home
        @uid = uid
      end

      def label = "io.github.mediocretes.afterburner.#{name.gsub(/[^A-Za-z0-9.-]/, '-')}"
      def plist_path = File.join(@home, "Library", "LaunchAgents", "#{label}.plist")
      def log_path = File.join(@project, ".afterburner", "afterburner.log")
      def installed? = File.exist?(plist_path)
      def where = "launchd agent #{label}, logging to #{log_path}"

      def on
        check_project!
        FileUtils.mkdir_p([File.dirname(plist_path), File.dirname(log_path)])
        File.write(plist_path, plist)
        @runner.call("launchctl", "bootout", "gui/#{@uid}/#{label}") # an older copy, if any
        unless @runner.call("launchctl", "bootstrap", "gui/#{@uid}", plist_path)
          raise Error, "launchctl couldn't load #{plist_path}"
        end

        @out.puts "afterburner will start at login for #{@project}, and is starting now."
        @out.puts "Its log: #{log_path}"
        if running?
          @out.puts "Port #{@port} is already in use (your own `afterburner watch`?). The background one keeps retrying until it's free."
        end
      end

      def off
        @runner.call("launchctl", "bootout", "gui/#{@uid}/#{label}")
        removed = File.exist?(plist_path) && File.delete(plist_path)
        @out.puts(removed ? "afterburner won't start at login any more, and the background one has stopped." : "afterburner wasn't set to start at login for #{@project}.")
      end

      def plist
        arguments = command.map { "    <string>#{xml(_1)}</string>" }.join("\n")
        path = [File.dirname(RbConfig.ruby), "/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin"].uniq.join(":")
        <<~XML
          <?xml version="1.0" encoding="UTF-8"?>
          <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
          <!-- Written by `afterburner autostart on`; remove with `afterburner autostart off`. -->
          <plist version="1.0">
          <dict>
            <key>Label</key>
            <string>#{xml(label)}</string>
            <key>ProgramArguments</key>
            <array>
          #{arguments}
            </array>
            <key>WorkingDirectory</key>
            <string>#{xml(@project)}</string>
            <key>EnvironmentVariables</key>
            <dict>
              <key>LANG</key>
              <string>en_US.UTF-8</string>
              <key>PATH</key>
              <string>#{xml(path)}</string>
            </dict>
            <key>RunAtLoad</key>
            <true/>
            <!-- Restart it if it stops with an error (a busy port, say), but not more than every 30 seconds. -->
            <key>KeepAlive</key>
            <dict>
              <key>SuccessfulExit</key>
              <false/>
            </dict>
            <key>ThrottleInterval</key>
            <integer>30</integer>
            <key>StandardOutPath</key>
            <string>#{xml(log_path)}</string>
            <key>StandardErrorPath</key>
            <string>#{xml(log_path)}</string>
          </dict>
          </plist>
        XML
      end

      private

      def xml(text) = text.to_s.gsub("&", "&amp;").gsub("<", "&lt;").gsub(">", "&gt;")
    end

    # The Startup folder on Windows.
    class Windows < Autostart
      def initialize(startup: File.join(ENV.fetch("APPDATA", Dir.home), "Microsoft", "Windows", "Start Menu", "Programs", "Startup"), **options)
        super(**options)
        @startup = startup
      end

      def script_path = File.join(@startup, "afterburner (#{name}).cmd")
      def installed? = File.exist?(script_path)
      def where = "#{script_path}, in a minimized window"

      def on
        check_project!
        FileUtils.mkdir_p(@startup)
        File.write(script_path, script, mode: "wb")
        @out.puts "afterburner will start at login for #{@project}, in a minimized window; close it to stop afterburner."
        if running?
          @out.puts "Port #{@port} is already in use (your own `afterburner watch`?), so it won't start a second one now."
        else
          @runner.call("cmd.exe", "/c", script_path)
          @out.puts "It's starting now."
        end
      end

      def off
        removed = File.exist?(script_path) && File.delete(script_path)
        @out.puts(removed ? "afterburner won't start at login any more. A running one keeps going until you close its window." : "afterburner wasn't set to start at login for #{@project}.")
      end

      def script
        program, *arguments = command.map { cmd_quote(_1) }
        [
          "@echo off",
          "rem Written by `afterburner autostart on`; remove with `afterburner autostart off`.",
          "cd /d #{cmd_quote(@project)}",
          "start \"afterburner - #{name.gsub('%', '%%')}\" /min #{program} #{arguments.join(' ')}",
          "",
        ].join("\r\n")
      end

      private

      # Backslashes, quotes, and doubled % for a .cmd file.
      def cmd_quote(text) = "\"#{text.tr('/', '\\').gsub('%', '%%')}\""
    end
  end
end
