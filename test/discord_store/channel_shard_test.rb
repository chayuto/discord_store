# frozen_string_literal: true

require "test_helper"

class ChannelShardTest < Minitest::Test
  def test_requires_at_least_one_channel
    assert_raises(DiscordStore::ConfigurationError) { DiscordStore::ChannelShard.new([]) }
  end

  def test_assignment_is_stable
    shard = DiscordStore::ChannelShard.new(%w[1 2 3])

    assert_equal shard.for("orders"), shard.for("orders")
  end

  def test_distribution_is_even
    shard = DiscordStore::ChannelShard.new(%w[1 2 3 4])
    counts = (1..4000).group_by { |i| shard.for("stream_#{i}") }.transform_values(&:size)

    assert_equal 4, counts.size
    counts.each_value { |count| assert_in_delta 1000, count, 150 }
  end

  def test_adding_a_channel_moves_only_its_share
    keys = (1..2000).map { |i| "s#{i}" }
    before = DiscordStore::ChannelShard.new(%w[1 2 3]).plan(keys)
    after = DiscordStore::ChannelShard.new(%w[1 2 3 4]).plan(keys)
    moved = keys.count { |key| before[key] != after[key] }

    # Rendezvous hashing moves ~1/n. Modulo would move about three quarters,
    # and every moved stream loses its ordering guarantee across the move.
    assert_in_delta 500, moved, 120
  end

  def test_single_channel_is_totally_ordered
    assert_predicate DiscordStore::ChannelShard.new(%w[1]), :totally_ordered?
    refute_predicate DiscordStore::ChannelShard.new(%w[1 2]), :totally_ordered?
  end
end
