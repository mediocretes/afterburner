# frozen_string_literal: true

require_relative "test_helper"

class ApiTest < Minitest::Test
  include FixtureApi

  def resolve(name, path = []) = api.resolve(path, name)

  def test_snake_case_and_the_javascript_name_both_resolve
    assert_equal ["getServerMaxMoney"], resolve("get_server_max_money").path
    assert_equal ["getServerMaxMoney"], resolve("getServerMaxMoney").path
  end

  def test_getters_drop_get
    assert_equal ["getServerMaxMoney"], resolve("server_max_money").path
    assert_equal ["getHackingLevel"], resolve("hacking_level").path
  end

  def test_short_aliases_never_shadow_a_real_function
    assert_equal ["server"], resolve("server").path
    assert_equal ["getServer"], resolve("get_server").path
  end

  def test_yes_no_questions_get_question_marks
    assert_equal ["hasRootAccess"], resolve("root_access?").path
    assert_equal ["hasRootAccess"], resolve("has_root_access?").path
    assert_equal ["isRunning"], resolve("running?").path
  end

  def test_functions_that_do_something_dont
    assert resolve("nuke")
    assert_nil resolve("nuke?")
  end

  def test_namespaces_and_their_functions
    assert_predicate resolve("hacknet"), :namespace?
    entry = resolve("num_nodes", ["hacknet"])
    assert_equal ["hacknet", "numNodes"], entry.path
    assert_equal "hacknet.numNodes", entry.qualified_name
    assert_in_delta 0.5, entry.ram
  end

  def test_inherited_members
    assert_equal ["child", "inherited"], resolve("inherited", ["child"]).path
    assert_in_delta 1.0, resolve("inherited", ["child"]).ram
  end

  def test_inline_object_namespaces
    assert_predicate resolve("heart"), :namespace?
    assert_equal ["heart", "break"], resolve("break", ["heart"]).path
  end

  def test_properties
    assert_predicate resolve("args"), :property?
    assert_predicate resolve("pid"), :property?
  end

  def test_ram_costs_come_from_the_doc_comments
    assert_in_delta 0.1, resolve("hack").ram
    assert_in_delta 2.0, resolve("get_server").ram
    assert_in_delta 0.1, resolve("running?").ram # signature spans lines
  end

  def test_unknown_names
    assert_nil resolve("hakc")
    assert_nil resolve("num_nodes")
    assert_includes api.suggestions([], "server_max_mony"), "server_max_money"
  end

  def test_lists_every_function
    names = api.functions.map(&:qualified_name)
    assert_includes names, "hack"
    assert_includes names, "hacknet.numNodes"
    assert_includes names, "child.inherited"
    refute_includes names, "args"
  end

  def test_ram_for_counts_each_function_once
    assert_in_delta 1.8, api.ram_for(%w[hack getServerMaxMoney hack])
    assert_in_delta 1.6, api.ram_for(%w[tprint not.a.function])
  end

  def test_generic_and_declared_interfaces
    definitions = <<~TS
      interface Base<T> {
        /**
         * RAM cost: 1 GB
         */
        inherited(): T;
      }
      export declare interface NS extends Base<number> {
        readonly args: ScriptArg[];
      }
    TS
    assert_equal ["inherited"], Afterburner::Api.new(definitions).resolve([], "inherited").path
  end

  def test_name_conversions
    assert_equal "get_server_max_money", Afterburner::Api.underscore("getServerMaxMoney")
    assert_equal "additionalMsec", Afterburner::Api.camelize(:additional_msec)
  end

  def test_parses_the_real_definitions_if_present
    path = ENV.fetch("AFTERBURNER_DEFINITIONS", File.expand_path("../NetscriptDefinitions.d.ts", __dir__))
    skip "no NetscriptDefinitions.d.ts; set AFTERBURNER_DEFINITIONS to the game's copy" unless File.exist?(path)

    real = Afterburner::Api.load(path)
    assert_operator real.functions.count, :>, 400
    assert_equal ["hacknet", "numNodes"], real.resolve(["hacknet"], "num_nodes").path
    assert_equal ["cloud", "purchaseServer"], real.resolve(["cloud"], "purchase_server").path
  end
end
