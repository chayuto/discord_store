# frozen_string_literal: true

require_relative "log/record"

module DiscordStore
  # An append-only log whose storage is a set of Discord channels.
  #
  # This is the layer everything else is built on, and it is append-only for a
  # reason that is worth stating plainly, because it is the joke at the centre
  # of this library.
  #
  # Deleting from Discord is expensive and gets worse with age: bulk deletion
  # only covers messages under two weeks old, and past that it is one request
  # per message against a rate limit that is already the binding constraint. So
  # the cheap way to retire a record is to append a marker saying it is gone and
  # let the reader skip it.
  #
  # That marker is a tombstone. Discord's own storage layer, Cassandra, did the
  # same thing for the same reason — and the volume of tombstones a chat app
  # generates is precisely what made Cassandra untenable for them and forced the
  # migration to ScyllaDB. Building a store on Discord means writing tombstones
  # into a database whose tombstones are stored as tombstones.
  #
  # Compaction is therefore not optional at scale; see {#compact}.
  class Log
    # @return [ChannelShard]
    attr_reader :shard

    # @return [Transport::REST]
    attr_reader :rest

    # @param rest [Transport::REST]
    # @param config [Configuration]
    # @param channel_ids [Array<String>, nil] defaults to config.log_channel_ids
    # @param cipher [#seal, #open, nil]
    def initialize(rest:, config:, channel_ids: nil, cipher: nil)
      @rest = rest
      @config = config
      @shard = ChannelShard.new(channel_ids || config.log_channel_ids)
      @cipher = cipher || Cipher.build(config)
      @codec = Codec.new(cipher: @cipher, content_budget: config.content_budget)
    end

    # Appends one record.
    #
    # @param stream [String] logical topic and partition key
    # @param data [Hash]
    # @param nonce [String, nil] pass a stable value to make a retry idempotent
    # @return [Log::Record] with +lsn+ assigned
    def append(stream:, data:, nonce: nil)
      append_all([Record.new(stream: stream, data: data, nonce: nonce)]).first
    end

    # Appends several records.
    #
    # Records are grouped by partition and packed, so N records cost far fewer
    # than N requests. With +atomic+, every record must land in one message or
    # the call raises: one message is the largest unit Discord commits
    # all-or-nothing, and that is the only atomicity on offer here.
    #
    # @param records [Array<Log::Record>]
    # @param atomic [Boolean]
    # @return [Array<Log::Record>] the same records, with +lsn+ assigned
    def append_all(records, atomic: false)
      records = Array(records)
      return [] if records.empty?

      by_channel = records.group_by { |record| @shard.for(record.stream) }

      if atomic && by_channel.size > 1
        raise PayloadTooLargeError,
              "an atomic batch spans #{by_channel.size} partitions (#{by_channel.keys.join(", ")}). " \
              "Records that must commit together must share a partition; give them the same " \
              "stream, or configure a single log channel."
      end

      by_channel.flat_map do |channel_id, channel_records|
        write_to_channel(channel_id, channel_records, atomic: atomic)
      end
    end

    # Buffers appends and writes them as one atomic batch on success.
    #
    #   log.transaction do |tx|
    #     tx.append(stream: "orders", data: { id: 1 })
    #     tx.append(stream: "orders", data: { id: 2 })
    #   end
    #
    # Nothing is written if the block raises.
    #
    # @yieldparam buffer [Buffer]
    # @return [Array<Log::Record>]
    def transaction
      buffer = Buffer.new
      yield buffer
      return [] if buffer.empty?

      append_all(buffer.records, atomic: true)
    end

    # Reads records in partition order.
    #
    # @param stream [String, nil] a single stream, or nil for every partition
    # @param after [String, nil] a cursor from {Record#cursor}; exclusive
    # @param limit [Integer, nil]
    # @yieldparam record [Log::Record]
    # @return [Array<Log::Record>, void]
    def each(stream: nil, after: nil, limit: nil, &block)
      return enum_for(:each, stream: stream, after: after, limit: limit) unless block

      channels = stream ? [@shard.for(stream)] : @shard.channel_ids
      count = 0

      channels.each do |channel_id|
        read_channel(channel_id, after: after, stream: stream) do |record|
          block.call(record)
          count += 1
          # Non-local on purpose: the limit applies to the whole walk across
          # every partition, not to the current channel.
          return if limit && count >= limit # rubocop:disable Lint/NonLocalExitFromIterator
        end
      end
    end

    # @return [Array<Log::Record>]
    def read(stream: nil, after: nil, limit: nil)
      each(stream: stream, after: after, limit: limit).to_a
    end

    # The cursor of the most recent record in a partition, or nil if empty.
    #
    # @param stream [String, nil]
    # @return [String, nil]
    def tip(stream: nil)
      channel_id = stream ? @shard.for(stream) : @shard.channel_ids.first
      message = @rest.list_messages(channel_id, limit: 1).first
      return nil unless message && @codec.ours?(message)

      records = decode(message)
      records.last&.cursor
    end

    # Appends a tombstone for +target+.
    #
    # @param stream [String]
    # @param target [String] the cursor or key being retired
    # @return [Log::Record]
    def tombstone(stream:, target:)
      append_all([Record.tombstone(stream: stream, target: target)]).first
    end

    # Rewrites a message in place. Only valid for a message holding exactly one
    # record; a packed message cannot be edited record-wise without rewriting
    # its neighbours, and rewriting history in an append-only log is how replays
    # start disagreeing with each other.
    #
    # @param record [Log::Record]
    # @param data [Hash]
    # @return [Log::Record]
    def replace(record, data:)
      raise ArgumentError, "record has no lsn" unless record.lsn

      channel_id = record.channel_id || @shard.for(record.stream)
      updated = Record.new(stream: record.stream, data: data, nonce: record.nonce,
                           lsn: record.lsn, position: 0, channel_id: channel_id)

      packed = @codec.pack([updated], aad: channel_id, atomic: true).first

      unless packed[:files].empty?
        raise PayloadTooLargeError, "replacement spills to an attachment; append a new record instead"
      end

      @rest.edit_message(channel_id, record.lsn, content: packed[:content])
      updated
    end

    # Discards tombstoned records by physically deleting their messages.
    #
    # This is the expensive path, and the only one that reclaims anything. It is
    # deliberately explicit rather than automatic: it costs one request per
    # message once the two-week bulk-delete window has closed, which at the
    # per-channel limit is roughly one message per second.
    #
    # @param stream [String]
    # @param dry_run [Boolean] report what would be deleted without deleting
    # @return [Hash] {scanned:, tombstoned:, deleted:, too_old:}
    def compact(stream:, dry_run: false)
      channel_id = @shard.for(stream)
      targets = []
      scanned = 0

      read_channel(channel_id, stream: stream) do |record|
        scanned += 1
        targets << record.data["target"] if record.tombstone?
      end

      doomed = targets.filter_map { |cursor| cursor.to_s.split(":").first }.uniq

      return { scanned: scanned, tombstoned: doomed.size, deleted: 0, too_old: 0, dry_run: true } if dry_run

      too_old = @rest.bulk_delete_messages(channel_id, doomed)

      if @config.delete_policy == :aggressive
        too_old.each { |id| @rest.delete_message(channel_id, id) }
        too_old = []
      end

      { scanned: scanned, tombstoned: doomed.size,
        deleted: doomed.size - too_old.size, too_old: too_old.size, dry_run: false }
    end

    private

    def write_to_channel(channel_id, records, atomic:)
      packed = @codec.pack(records, aad: channel_id, atomic: atomic)

      packed.flat_map do |message|
        # One nonce per message, derived from the first record, so that a retry
        # after a timeout is deduplicated by Discord rather than duplicated by us.
        response = @rest.create_message(
          channel_id,
          content: message[:content],
          nonce: message[:records].first.nonce,
          files: message[:files]
        )

        message[:records].each_with_index.map do |record, position|
          Record.new(stream: record.stream, data: record.data, nonce: record.nonce,
                     lsn: response["id"], position: position, channel_id: channel_id)
        end
      end
    end

    def read_channel(channel_id, after: nil, stream: nil)
      after_param, cursor_lsn, skip_position = parse_cursor(after)

      @rest.each_message(channel_id, after: after_param) do |message|
        next unless @codec.ours?(message)

        decode(message).each do |record|
          next if cursor_lsn && record.lsn == cursor_lsn && record.position <= skip_position
          next if stream && record.stream != stream

          yield record
        end
      end
    end

    def decode(message)
      body = @codec.spilled?(message) ? fetch_spill(message) : nil
      @codec.unpack(message, attachment_body: body, aad: message["channel_id"])
    end

    # Re-resolves the attachment URL from the message we are holding right now.
    # A URL read from anywhere else is a URL that has probably expired.
    def fetch_spill(message)
      attachment = message["attachments"]&.first
      unless attachment
        raise CorruptRecordError,
              "message #{message["id"]} claims a spill but has no attachment"
      end

      @rest.download(attachment["url"])
    end

    # Discord's +after+ is exclusive on message ID, so resuming inside a packed
    # message means asking for the message itself back and then skipping the
    # records already consumed.
    #
    # Returns three values, and the distinction between the first two matters:
    # the bound sent to Discord is the cursor's message ID minus one, while the
    # ID compared against each record is the cursor's own. Using the decremented
    # value for both silently re-delivers the last record of every resume.
    #
    # @return [Array(String, String, Integer)] api bound, cursor lsn, skip position
    def parse_cursor(cursor)
      return [nil, nil, nil] if cursor.nil?

      lsn, position = cursor.to_s.split(":")
      [(lsn.to_i - 1).to_s, lsn, position.to_i]
    end

    # Collects records for {Log#transaction}.
    class Buffer
      attr_reader :records

      def initialize = @records = []

      def append(stream:, data:, nonce: nil)
        record = Record.new(stream: stream, data: data, nonce: nonce)
        @records << record
        record
      end

      def empty? = @records.empty?
      def size = @records.size
    end
  end
end
