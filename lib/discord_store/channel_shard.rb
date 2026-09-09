# frozen_string_literal: true

require "digest"

module DiscordStore
  # Routes a logical stream to one of several channels.
  #
  # Discord's harshest limit is five messages per five seconds *per channel*.
  # The global token budget is ten times that, so a single-channel store leaves
  # ninety percent of its allowance unused, and the only way to spend it is to
  # write to more channels.
  #
  # That buys throughput and costs ordering, and it is worth being precise about
  # which: message IDs are only strictly ordered within a channel, because
  # Discord issues them from several workers. So this library makes the same
  # promise Kafka does — a channel is a partition, records within a partition
  # are totally ordered, and records in different partitions are not ordered
  # with respect to each other at all. A stream always lands in the same
  # partition, so per-stream order is total.
  #
  # If you need one order across everything, use one channel and accept the
  # ceiling. Correctness first; the ceiling is a documented number, whereas a
  # silently reordered write-ahead log is a bug you find much later.
  class ChannelShard
    # @return [Array<String>]
    attr_reader :channel_ids

    # @param channel_ids [Array<String>]
    # @raise [ConfigurationError] if no channels were given
    def initialize(channel_ids)
      ids = Array(channel_ids).compact.map(&:to_s).uniq
      raise ConfigurationError, "at least one channel id is required" if ids.empty?

      @channel_ids = ids.freeze
    end

    # The channel that owns +key+.
    #
    # Rendezvous hashing rather than modulo, so that adding a channel moves only
    # the fraction of streams that must move (1/n) instead of almost all of
    # them. A stream that changes partition loses its ordering guarantee across
    # the move, so the cheaper the reshuffle the better.
    #
    # @param key [#to_s] the stream name
    # @return [String] a channel id
    def for(key)
      return @channel_ids.first if @channel_ids.one?

      @channel_ids.max_by { |channel_id| weight(key, channel_id) }
    end

    # @return [Integer]
    def size = @channel_ids.size

    # @return [Boolean] whether this shard preserves a single total order
    def totally_ordered? = @channel_ids.one?

    # Every stream-to-channel assignment for a known set of streams, for
    # inspection and for tests that assert stability across reconfiguration.
    #
    # @param keys [Array<String>]
    # @return [Hash{String => String}]
    def plan(keys)
      keys.to_h { |key| [key.to_s, self.for(key)] }
    end

    private

    def weight(key, channel_id)
      Digest::SHA256.digest("#{key}\x00#{channel_id}").unpack1("Q>")
    end
  end
end
