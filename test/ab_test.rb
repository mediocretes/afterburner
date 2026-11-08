# frozen_string_literal: true

require_relative "test_helper"

class AbTest < Minitest::Test
  include FixtureApi

  FakeSession = Struct.new(:api)

  def with_session
    Fiber[:afterburner_session] = FakeSession.new(api)
    yield
  ensure
    Fiber[:afterburner_session] = nil
  end

  def docs = Afterburner::AB::Docs.new(api)

  def test_lookup_takes_ruby_or_javascript_names_through_namespaces
    assert_equal ["hacknet", "numNodes"], api.lookup("hacknet.num_nodes").path
    assert_equal ["hacknet", "numNodes"], api.lookup("ns.hacknet.numNodes").path
    assert_equal ["hasRootAccess"], api.lookup(:root_access?).path
    assert_nil api.lookup("hack.num_nodes")
    assert_nil api.lookup("nope")
  end

  def test_parser_keeps_docs_and_signatures
    member = api.member(api.lookup(:hack))
    assert_equal "hack(host?: string, opts?: BasicHGWOptions): Promise<number>;", member.signature
    assert_includes member.doc, "Steal money."
  end

  def test_ruby_names_shortest_first_and_only_ones_that_resolve
    assert_equal %w[root_access? has_root_access has_root_access?], api.ruby_names_for(api.lookup(:hasRootAccess))
    # The fixture's own server() takes getServer's short alias.
    assert_equal %w[get_server], api.ruby_names_for(api.lookup(:getServer))
    assert_equal "ns.hacknet.num_nodes", api.ruby_call(api.lookup("hacknet.numNodes"))
  end

  def test_ns_methods_lists_ruby_names_not_javascript_ones
    ns = Afterburner::NS.new(nil, api)
    assert_includes ns.methods, :root_access?
    assert_includes ns.methods, :hacknet
    assert_includes ns.methods, :server_max_money
    refute_includes ns.methods, :getServerMaxMoney
    assert_equal %i[num_nodes], ns.hacknet.methods
    assert ns.respond_to?(:methods)
  end

  def test_function_doc
    text = docs.function(api.lookup(:hack))
    lines = text.lines.map(&:rstrip)
    assert_equal "ns.hack(host = nil, **opts) → number    0.1 GB", lines[0]
    assert_equal "  JavaScript: ns.hack(host?: string, opts?: BasicHGWOptions): Promise<number>", lines[1]
    assert_includes text, "  opts, as keywords:"
    assert_match(/^    threads: number +Number of threads to use\. At most the script's own\.$/, text)
    assert_match(/^    additional_msec: number +Wait this much longer\.$/, text)
    assert_includes text, "See getServer and numNodes."
    assert_includes text, "@param host - The target."
    refute_includes text, "RAM cost"
    refute_includes text, "@remarks"
    refute_includes text, "*/"
  end

  def test_function_doc_mentions_other_names_and_handles_multiline_signatures
    text = docs.function(api.lookup(:running?))
    assert_equal "ns.running?(script, host = nil) → boolean    0.1 GB", text.lines.first.rstrip
    assert_includes text, "  Also: is_running, is_running?"
  end

  def test_rest_parameters
    assert_equal "ns.tprint(*args) → void    0 GB", docs.function(api.lookup(:tprint)).lines.first.rstrip
  end

  def test_property_doc
    assert_equal "ns.pid → number", docs.function(api.lookup(:pid))
  end

  def test_namespace_doc_lists_its_functions
    text = docs.namespace(api.lookup(:hacknet))
    assert_includes text, "ns.hacknet: 1 functions"
    assert_match(/^ns\.hacknet\.num_nodes +0\.5 GB +hacknet\.numNodes$/, text)
  end

  def test_unknown_names_get_suggestions
    assert_equal "No function or namespace called `hakc'. Did you mean? hack", docs.unknown("hakc")
    assert_equal "No function or namespace called `hacknet.num_node'. Did you mean? num_nodes",
                 docs.unknown("hacknet.num_node")
  end

  def test_ab_prints_through_the_current_session
    with_session do
      assert_output(/\Ans\.hack\(host = nil, \*\*opts\)/) { AB.doc(:hack) }
      assert_output(/hasRootAccess\n.*getServerMaxMoney|getServerMaxMoney\n.*hasRootAccess/m) { AB.functions(/root|max_money/) }
      assert_output("(no functions match)\n") { AB.functions("zzz") }
    end
  end

  def test_ab_outside_a_session_says_where_it_works
    error = assert_raises(NameError) { AB.functions }
    assert_match(/afterburner console/, error.message)
  end
end
