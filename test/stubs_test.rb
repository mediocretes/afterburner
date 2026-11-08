# frozen_string_literal: true

require_relative "test_helper"

class StubsTest < Minitest::Test
  include FixtureApi

  def setup
    @dir = Dir.mktmpdir
    @src = File.join(@dir, "src")
    @dist = File.join(@dir, "dist")
    FileUtils.mkdir_p([@src, @dist])
    @definitions = File.join(@dir, "NetscriptDefinitions.d.ts")
    File.write(@definitions, FIXTURE_DEFINITIONS)
    @costs = Afterburner::RamCosts.new(File.join(@dir, "costs.json"))
    @log = StringIO.new
    @link = RecordingLink.new
  end

  def teardown = FileUtils.remove_entry(@dir)

  def write(name, text, root: @src)
    path = File.join(root, name)
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, text)
  end

  def stubs
    @stubs ||= Afterburner::Stubs.new(scripts: Afterburner::Scripts.new(@src), definitions: @definitions, costs: @costs,
                                      port: 12_525, twins: [@dist, @src], log: quiet_log(@log))
  end

  def test_a_stub_claims_the_scripts_ram_and_hands_off
    write("farm.rb", "ns.hack(ARGV.first)")
    content = stubs.render.fetch("farm.js").content
    assert content.start_with?(Afterburner::Stubs::MARKER)
    assert_includes content, "// RAM: 1.6 base + hack 0.1"
    assert_includes content, 'import { serve } from "afterburner/proxy";'
    assert_includes content, "ns.ramOverride(1.7);"
    assert_includes content, 'await serve(ns, "farm.rb", 12525, 1.7);'
  end

  def test_subdirectories_and_libraries
    write("tools/scan.rb", "ns.hacking_level")
    write("lib/helpers.rb", "ns.hack('x')")
    assert_equal ["tools/scan.js"], stubs.render.keys
  end

  def test_skips_a_script_that_would_collide_with_another_file
    write("farm.rb", "ns.hack('x')")
    write("farm.js", "export async function main() {}", root: @dist)
    assert_empty stubs.render
    assert_includes @log.string, "skipping farm.rb"
  end

  def test_reports_unknown_functions
    write("typo.rb", "ns.hakc('x')")
    stubs.render
    assert_includes @log.string, "ns.hakc isn't a Netscript function"
  end

  def test_uses_measured_costs
    @costs.save("hack" => 0.5)
    write("farm.rb", "ns.hack('x')")
    assert_includes stubs.render.fetch("farm.js").content, "ns.ramOverride(2.1);"
  end

  def test_nothing_until_the_game_sends_definitions
    File.delete(@definitions)
    write("farm.rb", "ns.hack('x')")
    assert_empty stubs.render
  end

  def test_push_all_sends_the_proxy_and_stubs_and_clears_orphans
    write("farm.rb", "ns.hack('x')")
    @link.files = [
      { "filename" => "old.js", "content" => "#{Afterburner::Stubs::MARKER} from old.rb." },
      { "filename" => "mine.js", "content" => "export async function main() {}" },
    ]
    stubs.push_all(@link)
    assert_equal Afterburner::Stubs.proxy_source, @link.pushed.fetch("afterburner/proxy.js")
    assert @link.pushed.key?("farm.js")
    assert_equal ["old.js"], @link.deleted
  end

  def test_tick_pushes_only_what_changed
    write("farm.rb", "ns.hack('x')")
    stubs.tick(@link)
    assert_equal ["farm.js"], @link.pushed.keys
    @link.pushed.clear
    stubs.tick(@link)
    assert_empty @link.pushed

    write("farm.rb", "ns.hack('x')\nns.hacking_level")
    File.utime(Time.now + 5, Time.now + 5, File.join(@src, "farm.rb"))
    stubs.tick(@link)
    assert_includes @link.pushed.fetch("farm.js"), "ns.ramOverride(1.75);"

    File.delete(File.join(@src, "farm.rb"))
    stubs.tick(@link)
    assert_equal ["farm.js"], @link.deleted
  end

  # The game takes a stub's static RAM from ns.ramOverride(<number>) without
  # scanning the code, but only when that's main's first statement and the
  # argument is a literal. Otherwise it charges every name in the stub and
  # proxy.js that matches any ns function: 33.7 GB for the console stub.
  def static_ram(content)
    first = content[/export async function main\(ns\) \{\n(.*)$/, 1].to_s.strip
    first[/\Ans\.ramOverride\((\d+(?:\.\d+)?)\);\z/, 1]&.then { Float(_1) }
  end

  def test_console_stub_claiming_gb
    content = stubs.console_source(Afterburner::ConsoleClaim.parse("8"))
    assert_equal 8.0, static_ram(content)
    assert_includes content, '"@console"'
    assert_includes content, "// RAM: 8 GB"
  end

  def test_console_stub_claiming_a_share_of_free_ram
    content = stubs.console_source(Afterburner::ConsoleClaim.parse("80%"))
    assert_equal 1.7, static_ram(content), "starts with just enough to look at the server"
    assert_includes content, "const free = ns.getServerMaxRam() - ns.getServerUsedRam() + ns.ramOverride();"
    assert_includes content, "ns.ramOverride(Math.floor(free * 0.8 * 100) / 100);"
    assert_includes content, "// RAM: 80% of the free RAM where it runs"
    assert_includes content, "ns.ramOverride());"
  end

  def test_script_stubs_start_with_a_literal_ram_override
    write("farm.rb", "ns.hack(ARGV.first)")
    rendered = stubs.render
    refute_empty rendered
    rendered.each_value { |stub| refute_nil static_ram(stub.content), stub.name }
  end

  def test_console_claims
    assert_equal 8.0, Afterburner::ConsoleClaim.parse("8").gb
    assert_equal 2.5, Afterburner::ConsoleClaim.parse(" 2.5 ").gb
    assert_equal 80.0, Afterburner::ConsoleClaim.parse("80%").percent
    assert_equal 50.0, Afterburner::ConsoleClaim.parse("50 %").percent
    assert_equal "80% of the free RAM where it runs", Afterburner::ConsoleClaim.parse(Afterburner::ConsoleClaim::DEFAULT).to_s
    %w[1 0% 101% lots -5%].each do |text|
      assert_raises(ArgumentError, text) { Afterburner::ConsoleClaim.parse(text) }
    end
  end
end
