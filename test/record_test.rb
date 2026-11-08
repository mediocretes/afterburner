# frozen_string_literal: true

require_relative "test_helper"

class RecordTest < Minitest::Test
  def server
    Afterburner::Codec.decode(
      "hostname" => "n00dles", "moneyMax" => 1_750_000, "hasAdminRights" => false,
      "backdoorInstalled" => true, "cpuCores" => 1, "nested" => { "minDifficulty" => 1 }, "ports" => [{ "openPortCount" => 0 }],
    )
  end

  def test_snake_case_readers
    assert_equal "n00dles", server.hostname
    assert_equal 1_750_000, server.money_max
    assert_equal 1, server.cpu_cores
  end

  def test_predicates_drop_has_and_is
    refute server.admin_rights?
    refute server.has_admin_rights?
    assert server.backdoor_installed?
  end

  def test_nested_objects_and_arrays_are_records_too
    assert_equal 1, server.nested.min_difficulty
    assert_equal 0, server.ports.first.open_port_count
  end

  def test_brackets_take_either_spelling
    assert_equal 1_750_000, server[:money_max]
    assert_equal 1_750_000, server["moneyMax"]
    assert_nil server[:nope]
  end

  def test_unknown_readers_raise
    assert_raises(NoMethodError) { server.nope }
    refute_respond_to server, :nope
    assert_respond_to server, :money_max
  end

  def test_to_h_and_pattern_matching
    assert_equal({ min_difficulty: 1 }, server.to_h[:nested])
    matched = case server
              in { has_admin_rights: false, money_max: Integer => max } then max
              end
    assert_equal 1_750_000, matched
  end

  def test_goes_back_to_the_game_unchanged
    assert_equal 1_750_000, Afterburner::Codec.encode([server]).first["moneyMax"]
  end

  def test_keyword_options_go_camel_case
    assert_equal [{ "additionalMsec" => 50, "stock" => true }], Afterburner::Codec.encode([{ additional_msec: 50, stock: true }])
  end

  def test_non_finite_numbers_survive_the_trip
    [Float::INFINITY, -Float::INFINITY].each do |value|
      assert_equal value, Afterburner::Codec.decode(Afterburner::Codec.encode(value))
    end
    assert_predicate Afterburner::Codec.decode(Afterburner::Codec.encode(Float::NAN)), :nan?
  end

  def test_blocks_cant_cross
    assert_raises(ArgumentError) { Afterburner::Codec.encode([-> {}]) }
  end
end
