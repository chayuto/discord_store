# frozen_string_literal: true

require "json"
require "base64"

module DiscordStore
  # Turns records into message payloads and back.
  #
  # A Discord message holds 2000 characters, and a request that carries one
  # 80-byte record is a request that spent the same rate-limit permit as one
  # carrying twenty. Since permits are the scarce resource, packing is not an
  # optimisation here — it is most of the throughput.
  #
  # Wire format of a message:
  #
  #   DS1 i 3            <- header: version, kind, record count
  #   <envelope>         <- one record per line, base64url so a line break
  #   <envelope>            can never appear inside one
  #   <envelope>
  #
  # A record too large to fit alongside anything else spills to an attachment
  # and the message body becomes a stub:
  #
  #   DS1 s 1
  #
  # Bigger than an attachment is the blob store's problem, not the log's.
  class Codec
    HEADER_PREFIX = "DS1"
    KIND_INLINE = "i"
    KIND_SPILL = "s"
    SPILL_FILENAME = "records.ds1"
    SEPARATOR = "\n"

    # @param cipher [#seal, #open]
    # @param content_budget [Integer] characters we are willing to use
    # @param spill_limit [Integer, nil] max attachment bytes; nil means unlimited
    def initialize(cipher:, content_budget: 1900, spill_limit: nil)
      @cipher = cipher
      @content_budget = content_budget
      @spill_limit = spill_limit
    end

    # Packs records into as few messages as will hold them.
    #
    # @param records [Array<Log::Record>]
    # @param aad [String, nil] bound into each envelope's authentication tag
    # @param atomic [Boolean] when true, refuse to split the batch across
    #   messages: either it fits in one message or it raises. One message is one
    #   atomic append, so this is how a transaction gets all-or-nothing
    #   durability on a platform with no transactions.
    # @return [Array<Hash>] each {content:, files:, records:}
    # @raise [PayloadTooLargeError]
    def pack(records, aad: nil, atomic: false)
      messages = []
      batch = Batch.new(inline_budget)

      records.each do |record|
        envelope = seal(record, aad)

        if envelope.length > inline_budget
          raise_if_atomic(atomic, "a single record exceeds one message")
          messages << current_message(batch.drain) if batch.any?
          messages << spill_message(record, envelope)
          next
        end

        unless batch.fits?(envelope)
          raise_if_atomic(atomic, "the batch does not fit in one message")
          messages << current_message(batch.drain)
        end

        batch.add(record, envelope)
      end

      messages << current_message(batch.drain) if batch.any?
      messages
    end

    # Reverses {#pack} for one Discord message.
    #
    # @param message [Hash] a Discord message object
    # @param attachment_body [String, nil] the spilled bytes, if the message has
    #   a spill attachment the caller has already fetched
    # @param aad [String, nil]
    # @return [Array<Log::Record>]
    def unpack(message, attachment_body: nil, aad: nil)
      content = message["content"].to_s
      header, body = split_header(content)
      return [] if header.nil?

      raw = if header[:kind] == KIND_SPILL
              unless attachment_body
                raise CorruptRecordError,
                      "message #{message["id"]} spilled to an attachment that was not fetched"
              end

              attachment_body
            else
              body
            end

      lines = raw.split(SEPARATOR).reject(&:empty?)

      if header[:count] != lines.size
        raise CorruptRecordError,
              "message #{message["id"]} claims #{header[:count]} records but carries #{lines.size}"
      end

      lines.each_with_index.map do |envelope, position|
        payload = JSON.parse(@cipher.open(envelope, aad: aad))
        Log::Record.from_wire(payload, lsn: message["id"], position: position,
                                       channel_id: message["channel_id"])
      end
    rescue JSON::ParserError => e
      raise CorruptRecordError, "message #{message["id"]} holds invalid JSON: #{e.message}"
    end

    # Whether a message looks like something this library wrote. Cheap enough to
    # run before doing any crypto.
    #
    # @param message [Hash]
    # @return [Boolean]
    def ours?(message)
      message.is_a?(Hash) && message["content"].to_s.start_with?("#{HEADER_PREFIX} ")
    end

    # @param message [Hash]
    # @return [Boolean] whether the payload lives in an attachment
    def spilled?(message)
      header, = split_header(message["content"].to_s)
      header && header[:kind] == KIND_SPILL
    end

    # Accumulates records until the next one would overflow a message.
    class Batch
      def initialize(budget)
        @budget = budget
        @pairs = []
        @size = 0
      end

      def any? = @pairs.any?

      # @return [Boolean] whether +envelope+ still fits alongside what is held
      def fits?(envelope)
        return true if @pairs.empty?

        @size + envelope.length + SEPARATOR.length <= @budget
      end

      def add(record, envelope)
        @size += envelope.length + (@pairs.empty? ? 0 : SEPARATOR.length)
        @pairs << [record, envelope]
      end

      # @return [Array] the accumulated pairs, resetting the batch
      def drain
        pairs = @pairs
        @pairs = []
        @size = 0
        pairs
      end
    end

    private

    def seal(record, aad)
      envelope = @cipher.seal(JSON.generate(record.to_wire), aad: aad)

      if envelope.include?(SEPARATOR)
        raise CorruptRecordError, "cipher produced a newline; envelopes must be single-line"
      end

      envelope
    end

    # Header plus the newline that follows it, plus one separator per record
    # after the first. Computed against the worst case so a full batch can never
    # overflow the hard 2000-character limit.
    def inline_budget
      @content_budget - (HEADER_PREFIX.length + 8)
    end

    def current_message(pairs)
      records = pairs.map(&:first)
      envelopes = pairs.map(&:last)

      {
        content: [header(KIND_INLINE, records.size), *envelopes].join(SEPARATOR),
        files: [],
        records: records
      }
    end

    def spill_message(record, envelope)
      if @spill_limit && envelope.bytesize > @spill_limit
        raise PayloadTooLargeError,
              "record is #{envelope.bytesize} bytes, over the #{@spill_limit}-byte attachment " \
              "ceiling. Store it as a blob instead of a log record."
      end

      {
        content: header(KIND_SPILL, 1),
        files: [{ filename: SPILL_FILENAME, content: envelope, content_type: "application/octet-stream" }],
        records: [record]
      }
    end

    def header(kind, count) = "#{HEADER_PREFIX} #{kind} #{count}"

    def split_header(content)
      header_line, body = content.split(SEPARATOR, 2)
      return [nil, nil] if header_line.nil?

      prefix, kind, count = header_line.split(" ", 3)
      return [nil, nil] unless prefix == HEADER_PREFIX
      return [nil, nil] unless [KIND_INLINE, KIND_SPILL].include?(kind)

      [{ kind: kind, count: count.to_i }, body.to_s]
    end

    def raise_if_atomic(atomic, reason)
      return unless atomic

      raise PayloadTooLargeError,
            "#{reason}, and this batch was requested atomic. One Discord message is the " \
            "largest thing that commits all-or-nothing; split the transaction or accept " \
            "that replay may observe it partially applied."
    end
  end
end
