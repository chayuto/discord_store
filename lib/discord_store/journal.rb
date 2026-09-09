# frozen_string_literal: true

require "base64"
require "bigdecimal"
require "time"

module DiscordStore
  # The write-ahead log behind the ActiveRecord adapter.
  #
  # Each entry is a SQL statement plus its bind values, which is logical
  # replication in the plainest possible form: replaying the statements in order
  # against an empty database reproduces the database. Postgres and MySQL both
  # ship a version of this idea; the only novelty here is that the log segment
  # is a Discord channel.
  #
  # Statements are journalled with their binds already materialised, because a
  # prepared statement handle means nothing to a reader on another machine three
  # months from now.
  class Journal
    STREAM = "wal"
    CURSOR_TABLE = "discord_store_journal"

    MODES = %i[sync async off].freeze

    # Tags for values JSON cannot carry losslessly.
    BINARY_TAG = "__b"
    TIME_TAG = "__t"
    DATE_TAG = "__D"
    DECIMAL_TAG = "__d"

    attr_reader :mode, :log

    # @param config [Configuration]
    # @param mode [Symbol] :sync, :async or :off
    # @param flush_interval [Numeric] seconds, for :async
    # @param max_buffer [Integer] entries, for :async
    # @param http [#call, nil] injectable transport
    def initialize(config:, mode: :sync, flush_interval: 1.0, max_buffer: 200, http: nil)
      raise ConfigurationError, "journal_mode must be one of #{MODES.join(", ")}" unless MODES.include?(mode)

      @mode = mode
      @flush_interval = flush_interval
      @max_buffer = max_buffer
      @buffer = []
      @mutex = Mutex.new
      @local_cursor = nil

      return if mode == :off

      @client = Client.new(config: config, http: http)
      @log = @client.log
      start_flusher if mode == :async
    end

    # @return [Boolean]
    def recording? = @mode != :off

    # Records one transaction.
    #
    # @param statements [Array<Hash>] each {"sql" =>, "binds" =>}
    # @return [String, nil] the cursor the transaction landed at, if written now
    def write(statements)
      return nil unless recording?
      return nil if statements.empty?

      entry = { "tx" => statements, "at" => Time.now.utc.iso8601(3) }

      case @mode
      when :sync
        append([entry]).last&.cursor
      when :async
        buffered = @mutex.synchronize do
          @buffer << entry
          @buffer.size
        end
        flush! if buffered >= @max_buffer
        nil
      end
    end

    # Writes anything buffered.
    #
    # @return [Integer] entries written
    def flush!
      return 0 unless @mode == :async

      pending = @mutex.synchronize do
        drained = @buffer
        @buffer = []
        drained
      end
      return 0 if pending.empty?

      append(pending)
      pending.size
    end

    # @return [Integer] entries waiting to be written
    def pending_count = @mutex.synchronize { @buffer.size }

    # @return [String, nil] cursor of the newest record in the channel
    def tip
      return nil unless recording?

      @log.tip(stream: STREAM)
    end

    # Reads transactions in order.
    #
    # @param from [String, nil] exclusive cursor
    # @yieldparam entry [Hash] {"tx" =>, "at" =>}
    # @yieldparam cursor [String]
    # @return [void]
    def each_transaction(from: nil)
      # Deliberately checks for a log rather than for recording?: a replay reads
      # while paused, and gating this on the write mode would make it a no-op
      # exactly when it matters.
      return if @log.nil?

      @log.each(stream: STREAM, after: from) do |record|
        data = record.data
        next unless data.is_a?(Hash) && data["tx"]

        yield data, record.cursor
      end
    end

    # How far the local database has been replayed.
    #
    # @return [String, nil]
    attr_accessor :local_cursor

    # Suspends writing for the duration of the block, leaving reads working.
    #
    # Replay uses this: applying a statement locally must not journal it back,
    # or every replay would duplicate the log it just read.
    #
    # @return [Object] the block's value
    def while_paused
      previous = @mode
      @mode = :off
      yield
    ensure
      @mode = previous
    end

    # @return [void]
    def close
      flush!
      @flusher&.kill
      @client&.close
    end

    # --- Bind serialisation ---------------------------------------------------

    # Turns ActiveRecord bind parameters into something JSON can carry, with
    # tags for the types it cannot.
    #
    # @param binds [Array]
    # @return [Array]
    def self.serialize_binds(binds)
      Array(binds).map do |bind|
        value = bind.respond_to?(:value_for_database) ? bind.value_for_database : bind
        serialize_value(value)
      end
    end

    # @param value [Object]
    # @return [Object]
    def self.serialize_value(value)
      case value
      when nil, true, false, Integer, Float then value
      when BigDecimal then { DECIMAL_TAG => value.to_s("F") }
      when Time then { TIME_TAG => value.utc.iso8601(6) }
      when DateTime then { TIME_TAG => value.to_time.utc.iso8601(6) }
      when Date then { DATE_TAG => value.iso8601 }
      when String
        # A UTF-8 string rides as itself; anything else is bytes, and bytes do
        # not survive JSON.
        if value.encoding == Encoding::BINARY || !value.valid_encoding?
          { BINARY_TAG => Base64.strict_encode64(value) }
        else
          value
        end
      else
        if value.respond_to?(:to_s) && value.class.name.to_s.include?("Binary")
          { BINARY_TAG => Base64.strict_encode64(value.to_s) }
        else
          value.to_s
        end
      end
    end

    # @param values [Array]
    # @return [Array]
    def self.deserialize_binds(values)
      Array(values).map { |value| deserialize_value(value) }
    end

    # @param value [Object]
    # @return [Object]
    def self.deserialize_value(value)
      return value unless value.is_a?(Hash)

      if value.key?(BINARY_TAG) then Base64.strict_decode64(value[BINARY_TAG])
      elsif value.key?(TIME_TAG) then Time.iso8601(value[TIME_TAG])
      elsif value.key?(DATE_TAG) then Date.iso8601(value[DATE_TAG])
      elsif value.key?(DECIMAL_TAG) then BigDecimal(value[DECIMAL_TAG])
      else value
      end
    end

    # Builds a {Configuration} from a database.yml stanza.
    #
    # @param options [Hash]
    # @return [Configuration]
    def self.build_configuration(options)
      Configuration.new.tap do |config|
        config.i_understand_this_violates_discord_tos =
          options[:i_understand_this_violates_discord_tos]
        config.token = options[:token]
        config.application_id = options[:application_id]
        config.guild_id = options[:guild_id]
        config.secret_key = options[:secret_key]
        config.cipher = (options[:cipher] || :aes_256_gcm).to_sym
        config.log_channel_ids = Array(options[:log_channel_ids]).map(&:to_s)
        config.logger = options[:logger]

        if config.log_channel_ids.size > 1
          raise ConfigurationError,
                "a write-ahead log needs one total order, and message IDs are only ordered " \
                "within a channel. Configure exactly one log_channel_id for the adapter, or " \
                "use DiscordStore::Log directly if per-stream ordering is enough."
        end
      end
    end

    private

    def append(entries)
      records = entries.map { |entry| Log::Record.new(stream: STREAM, data: entry) }
      @log.append_all(records)
    end

    def start_flusher
      @flusher = Thread.new do
        Thread.current.name = "discord_store-journal-flusher"
        loop do
          sleep(@flush_interval)
          begin
            flush!
          rescue StandardError => e
            warn "discord_store: journal flush failed: #{e.class}: #{e.message}"
          end
        end
      end
      @flusher.abort_on_exception = false

      at_exit { flush! }
    end
  end
end
