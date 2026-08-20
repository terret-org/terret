# frozen_string_literal: true

require "minitest/autorun"
require_relative "../ordering"

# The release build/push order is a topological sort of the gems' declared
# dependencies. Getting it wrong means pushing a gem before the versions it
# depends on exist on RubyGems, so `gem install terret` fails for the first
# person who tries it. These tests prove the order is a valid sort — read off
# the gemspecs, no network — rather than asserting a hand-written sequence.
class OrderingTest < Minitest::Test
  def setup
    @graph = Release::Ordering.graph
    @order = Release::Ordering.order(@graph)
  end

  def test_the_order_is_a_permutation_of_every_gem_in_the_repo
    assert_equal @graph.keys.sort, @order.sort
    assert_equal @order.uniq, @order, "a gem appears twice in the order"
  end

  # A deliberate release canary: twelve gems ship in this repo. If a gem is
  # added or removed, this fails so the release count is updated on purpose
  # rather than drifting silently.
  def test_twelve_gems_ship
    assert_equal 12, @order.length
  end

  def test_hames_is_first_and_the_meta_gem_is_last
    assert_equal "hames", @order.first
    assert_equal "terret", @order.last
  end

  def test_every_gem_comes_after_all_of_its_in_repo_dependencies
    position = @order.each_with_index.to_h
    @graph.each do |gem, deps|
      deps.each do |dep|
        assert_operator position.fetch(dep), :<, position.fetch(gem),
                        "#{gem} is pushed before its dependency #{dep}"
      end
    end
  end

  def test_the_graph_only_has_edges_to_in_repo_gems
    names = @graph.keys
    @graph.each_value do |deps|
      deps.each { |dep| assert_includes names, dep }
    end
  end

  # terret-tools-std depends on terret-exec as well as terret-core, so a valid
  # sort must place it after terret-exec — the one non-trivial edge in the graph
  # beyond "everything after terret-core".
  def test_tools_std_comes_after_exec
    position = @order.each_with_index.to_h
    assert_operator position.fetch("terret-exec"), :<, position.fetch("terret-tools-std")
  end
end
