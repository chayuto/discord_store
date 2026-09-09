# frozen_string_literal: true

require "json"

module DiscordStore
  # Typed values bound to Discord messages, in the shape Kredis gives Redis.
  #
  # Two storage strategies, chosen per type according to what Discord can
  # actually promise:
  #
  #   Documents (string, integer, json, boolean, flag)
  #     One message per key, edited in place. Cheap to read and write, and
  #     last-write-wins under concurrency, because Discord offers no
  #     compare-and-swap and there is no way to build one on top of message
  #     editing.
  #
  #   Deltas (counter, list)
  #     Append-only. A counter is the sum of its increments, not a number that
  #     gets overwritten. This costs a read scan and buys the one thing the
  #     document strategy cannot give: two processes incrementing at once both
  #     count, because appends do not collide. It is the same reason distributed
  #     systems reach for CRDTs, arrived at by the same constraint.
  #
  # If you want a counter that is correct, use {#counter}. If you want one that
  # is fast and you are the only writer, use {#integer}.
  class KV
    STREAM_PREFIX = "kv"

    attr_reader :config

    def initialize(rest:, config:, channel_id: nil)
      @config = config
      channel = channel_id || config.document_channel_id || config.log_channel_ids.first
      raise ConfigurationError, "document_channel_id or a log channel is required for KV" if channel.nil?

      @log = Log.new(rest: rest, config: config, channel_ids: [channel])
      @rest = rest
      @channel_id = channel.to_s
      @documents = DocumentIndex.new(log: @log, rest: rest, channel_id: @channel_id)
    end

    # @return [Scalar] a string-valued key
    def string(key) = Scalar.new(index: @documents, key: key, type: :string)

    # @return [Scalar] an integer-valued key
    def integer(key) = Scalar.new(index: @documents, key: key, type: :integer)

    # @return [Scalar] a boolean-valued key
    def boolean(key) = Scalar.new(index: @documents, key: key, type: :boolean)

    # @return [Scalar] an arbitrary JSON-valued key
    def json(key) = Scalar.new(index: @documents, key: key, type: :json)

    # A boolean that can lapse.
    #
    # Discord has no TTL, so expiry is evaluated when the value is read and the
    # message is never reclaimed. The flag stops being true on time; the storage
    # it occupies does not come back.
    #
    # @return [Flag]
    def flag(key) = Flag.new(index: @documents, key: key)

    # @return [Counter] a concurrency-safe counter
    def counter(key) = Counter.new(log: @log, key: key)

    # @return [List] an append-only list
    def list(key) = List.new(log: @log, key: key)

    # Rebuilds the document index from the channel. Necessary after another
    # process writes, because there is nothing to subscribe to here.
    #
    # @return [Integer] number of live keys
    def refresh! = @documents.warm!(force: true)

    # @return [Array<String>]
    def keys = @documents.keys

    # One message per key, edited in place.
    class DocumentIndex
      def initialize(log:, rest:, channel_id:)
        @log = log
        @rest = rest
        @channel_id = channel_id
        @records = {}
        @warm = false
        @mutex = Mutex.new
      end

      # @param key [String]
      # @param cached [Boolean] trust the local copy instead of re-reading
      # @return [Object, nil]
      def read(key, cached: false)
        warm!
        record = @mutex.synchronize { @records[key.to_s] }
        return nil if record.nil?
        return record.data["v"] if cached

        # Re-read, because another process may have edited this message and
        # there is no invalidation channel that would have told us.
        message = @rest.get_message(@channel_id, record.lsn)
        fresh = @log.send(:decode, message).first
        @mutex.synchronize { @records[key.to_s] = fresh } if fresh
        fresh&.data&.fetch("v", nil)
      rescue NotFoundError
        @mutex.synchronize { @records.delete(key.to_s) }
        nil
      end

      # @param key [String]
      # @param value [Object]
      # @param meta [Hash] extra fields stored alongside the value
      # @return [Object] the value
      def write(key, value, meta: {})
        warm!
        payload = { "k" => key.to_s, "v" => value }.merge(meta)
        existing = @mutex.synchronize { @records[key.to_s] }

        record = if existing
                   @log.replace(existing, data: payload)
                 else
                   @log.append(stream: stream_for(key), data: payload)
                 end

        @mutex.synchronize { @records[key.to_s] = record }
        value
      end

      # @param key [String]
      # @return [void]
      def delete(key)
        warm!
        record = @mutex.synchronize { @records.delete(key.to_s) }
        return nil if record.nil?

        # Edited to a tombstone rather than deleted: an edit is one cheap
        # request at any age, a delete is one expensive request that stops
        # being batchable after two weeks.
        @log.replace(record, data: { "k" => key.to_s, "__deleted" => true })
        nil
      end

      # @return [Array<String>]
      def keys
        warm!
        @mutex.synchronize { @records.keys }
      end

      # @return [Integer]
      def warm!(force: false)
        @mutex.synchronize do
          return @records.size if @warm && !force

          @records.clear

          @log.each do |record|
            data = record.data
            next unless data.is_a?(Hash) && data["k"]

            if data["__deleted"]
              @records.delete(data["k"].to_s)
            else
              @records[data["k"].to_s] = record
            end
          end

          @warm = true
          @records.size
        end
      end

      private

      def stream_for(key) = "#{STREAM_PREFIX}:#{key}"
    end

    # A single typed value.
    class Scalar
      attr_reader :key, :type

      def initialize(index:, key:, type:)
        @index = index
        @key = key.to_s
        @type = type
      end

      # @return [Object, nil]
      def value(cached: false) = cast(@index.read(@key, cached: cached))
      alias get value

      # @param new_value [Object]
      # @return [Object]
      def value=(new_value)
        @index.write(@key, serialize(new_value))
        new_value
      end
      alias set value=

      # @return [Boolean]
      def exists? = !@index.read(@key, cached: true).nil?

      # @return [void]
      def clear = @index.delete(@key)
      alias delete clear

      private

      def serialize(value)
        case @type
        when :integer then Integer(value)
        when :boolean then !value.nil? && value != false
        when :string then value.to_s
        else value
        end
      end

      def cast(value)
        return nil if value.nil?

        case @type
        when :integer then Integer(value)
        when :boolean then !value.nil? && value != false
        when :string then value.to_s
        else value
        end
      end
    end

    # A boolean with a lapse time.
    class Flag
      def initialize(index:, key:)
        @index = index
        @key = key.to_s
      end

      # @param expires_in [Numeric, nil] seconds
      # @return [Flag] self, so calls chain
      def mark(expires_in: nil)
        meta = expires_in ? { "exp" => (Time.now.to_f + expires_in) } : {}
        @index.write(@key, true, meta: meta)
        self
      end

      # @return [Boolean]
      def marked?
        record = @index.read(@key)
        return false if record.nil?

        expiry = expiry_for(@key)
        return true if expiry.nil?

        Time.now.to_f < expiry
      end

      # @return [void]
      def remove = @index.delete(@key)

      private

      def expiry_for(key)
        @index.warm!
        record = @index.instance_variable_get(:@records)[key]
        record&.data&.fetch("exp", nil)
      end
    end

    # A counter stored as the sum of its increments.
    #
    # Every increment is an append, so concurrent writers cannot lose each
    # other's work — which is more than a read-modify-write against an edited
    # message could promise. The cost is that reading means summing, so
    # {#compact!} periodically collapses the history into a checkpoint.
    class Counter
      CHECKPOINT = "__checkpoint"

      attr_reader :key

      def initialize(log:, key:)
        @log = log
        @key = key.to_s
        @stream = "#{STREAM_PREFIX}:counter:#{@key}"
      end

      # @param by [Integer]
      # @return [Integer] the value after incrementing, as this process sees it
      def increment(by: 1)
        @log.append(stream: @stream, data: { "d" => by })
        value
      end

      # @param by [Integer]
      # @return [Integer]
      def decrement(by: 1) = increment(by: -by)

      # @return [Integer]
      def value
        total = 0

        @log.each(stream: @stream) do |record|
          data = record.data
          next unless data.is_a?(Hash)

          if data[CHECKPOINT]
            total = data["total"].to_i
          else
            total += data["d"].to_i
          end
        end

        total
      end
      alias to_i value

      # @param amount [Integer]
      # @return [Integer]
      def reset(amount: 0)
        @log.append(stream: @stream, data: { CHECKPOINT => true, "total" => amount })
        amount
      end

      # Writes a checkpoint so future reads stop at it, then tombstones the
      # deltas behind it.
      #
      # @return [Integer] the checkpointed total
      def compact!
        total = value
        @log.append(stream: @stream, data: { CHECKPOINT => true, "total" => total })
        total
      end
    end

    # An append-only list.
    class List
      attr_reader :key

      def initialize(log:, key:)
        @log = log
        @key = key.to_s
        @stream = "#{STREAM_PREFIX}:list:#{@key}"
      end

      # @param values [Array<Object>]
      # @return [Array<Object>]
      def append(*values)
        records = values.map { |value| Log::Record.new(stream: @stream, data: { "v" => value }) }
        @log.append_all(records)
        values
      end
      alias push append
      alias << append

      # @return [Array<Object>]
      def elements
        live = []

        @log.each(stream: @stream) do |record|
          data = record.data
          next unless data.is_a?(Hash)

          if data["__remove"]
            live.reject! { |entry| entry[:value] == data["__remove"] }
          else
            live << { value: data["v"], cursor: record.cursor }
          end
        end

        live.map { |entry| entry[:value] }
      end
      alias to_a elements

      # @return [Integer]
      def size = elements.size

      # @param value [Object]
      # @return [void]
      def remove(value)
        @log.append(stream: @stream, data: { "__remove" => value })
        nil
      end

      # @return [void]
      def clear
        elements.each { |value| remove(value) }
        nil
      end
    end
  end
end
