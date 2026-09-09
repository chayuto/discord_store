# frozen_string_literal: true

module DiscordStore
  # Discord snowflake IDs, treated as what they actually are: a k-sortable
  # primary key with a millisecond timestamp baked into the high bits.
  #
  #   63                                    22     17     12            0
  #   +--------------------------------------+------+------+------------+
  #   | milliseconds since 2015-01-01 (42b)  | wrkr | proc | incr (12b) |
  #   +--------------------------------------+------+------+------------+
  #
  # Two properties matter for using Discord as a store:
  #
  # 1. IDs issued later sort after IDs issued earlier, so the natural message
  #    order in a channel *is* insertion order, and no separate sequence column
  #    is needed. The log sequence number is free.
  #
  # 2. Because the timestamp is recoverable, a wall-clock range maps onto an ID
  #    range. Discord's +before+/+after+ pagination parameters take snowflakes,
  #    so "every record written between 09:00 and 10:00" is a server-side range
  #    scan rather than a client-side filter over the whole channel.
  module Snowflake
    # Discord's epoch: 2015-01-01T00:00:00Z, in milliseconds.
    EPOCH_MS = 1_420_070_400_000

    TIMESTAMP_SHIFT = 22
    WORKER_SHIFT    = 17
    PROCESS_SHIFT   = 12

    WORKER_MASK    = 0x1F
    PROCESS_MASK   = 0x1F
    INCREMENT_MASK = 0xFFF

    # The largest value the 42-bit timestamp field can hold.
    MAX_TIMESTAMP_MS = (1 << 42) - 1

    module_function

    # Milliseconds since the Unix epoch at which +id+ was issued.
    #
    # @param id [Integer, String]
    # @return [Integer]
    def timestamp_ms(id)
      (Integer(id) >> TIMESTAMP_SHIFT) + EPOCH_MS
    end

    # @param id [Integer, String]
    # @return [Time] UTC time at which +id+ was issued
    def at(id)
      Time.at(timestamp_ms(id) / 1000.0).utc
    end

    # The worker/process/increment fields. Present for completeness and for
    # debugging odd ordering; nothing in this library depends on them.
    #
    # @param id [Integer, String]
    # @return [Hash]
    def parts(id)
      id = Integer(id)
      {
        timestamp_ms: timestamp_ms(id),
        worker: (id >> WORKER_SHIFT) & WORKER_MASK,
        process: (id >> PROCESS_SHIFT) & PROCESS_MASK,
        increment: id & INCREMENT_MASK
      }
    end

    # Build a synthetic snowflake for the given time, with all low bits zeroed.
    #
    # The result is not a real message ID and will never collide with one, but
    # it sorts exactly where a real ID issued at that instant would sort. That
    # makes it the correct bound for +before+/+after+ pagination when you want
    # a time range rather than a message range.
    #
    # @param time [Time, Integer] a Time, or milliseconds since the Unix epoch
    # @return [Integer]
    # @raise [ArgumentError] if the time predates Discord or overflows 42 bits
    def from_time(time)
      ms = time.is_a?(Time) ? (time.to_f * 1000).floor : Integer(time)
      offset = ms - EPOCH_MS

      raise ArgumentError, "time predates the Discord epoch (2015-01-01)" if offset.negative?
      raise ArgumentError, "time overflows the 42-bit snowflake timestamp" if offset > MAX_TIMESTAMP_MS

      offset << TIMESTAMP_SHIFT
    end

    # The same instant as {.from_time}, but with every low bit set, so that it
    # sorts after any real ID issued during that millisecond. Use this as an
    # inclusive upper bound.
    #
    # @param time [Time, Integer]
    # @return [Integer]
    def from_time_inclusive(time)
      from_time(time) | ((1 << TIMESTAMP_SHIFT) - 1)
    end

    # Whether +value+ could plausibly be a snowflake this library issued or read.
    #
    # @param value [Object]
    # @return [Boolean]
    def valid?(value)
      id = Integer(value)
      id.positive? && id < (1 << 64) && timestamp_ms(id) >= EPOCH_MS
    rescue ArgumentError, TypeError
      false
    end
  end
end
