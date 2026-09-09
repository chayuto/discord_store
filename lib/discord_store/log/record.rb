# frozen_string_literal: true

require "securerandom"

module DiscordStore
  class Log
    # One entry in the log.
    #
    # +lsn+ is the Discord message ID, which is a snowflake, which means the log
    # sequence number is free, globally unique, and carries its own timestamp.
    # +position+ disambiguates records packed into the same message.
    class Record
      attr_reader :stream, :data, :nonce, :lsn, :position, :channel_id

      # @param stream [String] logical topic; also the partition key
      # @param data [Hash] anything JSON can represent
      # @param nonce [String] idempotency key; Discord deduplicates on it
      def initialize(stream:, data:, nonce: nil, lsn: nil, position: 0, channel_id: nil)
        @stream = stream.to_s
        @data = data
        @nonce = nonce || SecureRandom.uuid
        @lsn = lsn&.to_s
        @position = position
        @channel_id = channel_id&.to_s
      end

      # When Discord accepted this record. Read straight out of the snowflake;
      # no created_at column required.
      #
      # @return [Time, nil]
      def created_at
        @lsn && Snowflake.at(@lsn)
      end

      # A cursor that orders correctly within a partition.
      #
      # @return [String, nil]
      def cursor
        @lsn && format("%<lsn>s:%<position>04d", lsn: @lsn, position: @position)
      end

      # @return [Boolean] whether this record marks a deleted predecessor
      def tombstone? = data.is_a?(Hash) && data["__tombstone"] == true

      # Wire form. Keys are short because every byte competes for the 2000
      # characters a message can hold, and a shorter key is one more record per
      # request.
      #
      # @return [Hash]
      def to_wire
        { "s" => stream, "n" => nonce, "d" => data }
      end

      # @param hash [Hash] a {#to_wire} payload
      # @return [Record]
      def self.from_wire(hash, lsn:, position:, channel_id: nil)
        unless hash.is_a?(Hash) && hash.key?("s")
          raise CorruptRecordError, "record at #{lsn}:#{position} is not a discord_store record"
        end

        new(stream: hash["s"], data: hash["d"], nonce: hash["n"],
            lsn: lsn, position: position, channel_id: channel_id)
      end

      # A record that marks +target+ deleted. The log never rewrites history, so
      # a delete is an append like everything else.
      #
      # @param stream [String]
      # @param target [String] the cursor or key being retired
      # @return [Record]
      def self.tombstone(stream:, target:)
        new(stream: stream, data: { "__tombstone" => true, "target" => target.to_s })
      end

      def ==(other)
        other.is_a?(Record) && other.stream == stream && other.data == data && other.nonce == nonce
      end
      alias eql? ==

      def hash = [stream, data, nonce].hash

      def inspect
        "#<DiscordStore::Log::Record stream=#{stream.inspect} lsn=#{lsn.inspect} " \
          "position=#{position} data=#{data.inspect}>"
      end
    end
  end
end
