# frozen_string_literal: true

require "test_helper"

class SnowflakeTest < Minitest::Test
  # A real Discord message ID, for a fixed point to check the epoch maths.
  KNOWN_ID = 175_928_847_299_117_063

  def test_recovers_the_timestamp
    assert_equal 1_462_015_105_796, DiscordStore::Snowflake.timestamp_ms(KNOWN_ID)
    assert_equal 2016, DiscordStore::Snowflake.at(KNOWN_ID).year
  end

  def test_parts_decode_the_bit_layout
    parts = DiscordStore::Snowflake.parts(KNOWN_ID)

    assert_equal 1, parts[:worker]
    assert_equal 0, parts[:process]
    assert_equal 7, parts[:increment]
  end

  def test_synthetic_ids_sort_where_a_real_one_would
    time = Time.utc(2026, 9, 9, 12, 0, 0)
    lower = DiscordStore::Snowflake.from_time(time)
    upper = DiscordStore::Snowflake.from_time_inclusive(time)

    assert_operator lower, :<, upper
    assert_equal time.to_i, DiscordStore::Snowflake.at(lower).to_i
    # Every ID issued in that millisecond falls inside the bracket.
    assert_operator lower + 1, :<, upper
  end

  def test_ids_are_k_sortable_by_time
    earlier = DiscordStore::Snowflake.from_time(Time.utc(2020, 1, 1))
    later = DiscordStore::Snowflake.from_time(Time.utc(2026, 1, 1))

    assert_operator earlier, :<, later
  end

  def test_rejects_times_outside_the_representable_range
    assert_raises(ArgumentError) { DiscordStore::Snowflake.from_time(Time.utc(2000, 1, 1)) }
    assert_raises(ArgumentError) { DiscordStore::Snowflake.from_time(Time.utc(2200, 1, 1)) }
  end

  def test_validity_check
    assert DiscordStore::Snowflake.valid?(KNOWN_ID)
    refute DiscordStore::Snowflake.valid?(0)
    refute DiscordStore::Snowflake.valid?("not a number")
  end
end
