# frozen_string_literal: true

require_relative "test_helper"

class NsTest < Minitest::Test
  include FixtureApi

  # Records what the proxy would send to the game.
  class RecordingSession
    attr_reader :calls

    def initialize = @calls = []

    def call(path, args)
      @calls << [path, args]
      "result"
    end
  end

  def setup
    @session = RecordingSession.new
    @ns = Afterburner::NS.new(@session, api)
  end

  def test_public_send_and_send_call_a_function_by_name
    assert_equal "result", @ns.public_send(:root_access?, "n00dles")
    @ns.send("hack", "n00dles", additional_msec: 50)
    @ns.__send__(:nuke, "n00dles")
    assert_equal [[["hasRootAccess"], ["n00dles"]], [["hack"], ["n00dles", { additional_msec: 50 }]], [["nuke"], ["n00dles"]]],
                 @session.calls
  end

  def test_public_send_reaches_namespaces
    @ns.public_send(:hacknet).public_send(:num_nodes)
    assert_equal [[["hacknet", "numNodes"], []]], @session.calls
  end

  def test_public_send_answers_ns_own_methods_itself
    assert_equal "#<NS ns>", @ns.public_send(:inspect)
    assert_includes @ns.send(:methods), :hack
    assert @ns.respond_to?(:public_send)
    assert @ns.respond_to?(:send)
  end

  def test_public_send_doesnt_reach_private_methods_or_unknown_names
    error = assert_raises(NoMethodError) { @ns.send(:call, "x", [], {}, nil) }
    assert_match(/has no function `call'/, error.message)
    assert_raises(NoMethodError) { @ns.public_send(:hakc, "x") }
    assert_empty @session.calls
  end
end
