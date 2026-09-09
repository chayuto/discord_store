# frozen_string_literal: true

require "net/http"
require "uri"
require "securerandom"

module DiscordStore
  module Transport
    # What every HTTP backend returns.
    Response = Struct.new(:status, :headers, :body, keyword_init: true) do
      def success? = status.between?(200, 299)
      def rate_limited? = status == 429
      def server_error? = status >= 500

      def json
        return nil if body.nil? || body.empty?

        require "json"
        JSON.parse(body)
      rescue JSON::ParserError
        nil
      end
    end

    # A request that has not been sent yet. Kept as a value object so the fake
    # backend can assert against exactly what the real one would have sent.
    #
    # The HTTP verb is +verb+, not +method+: a Struct member called method would
    # shadow Object#method, and losing that on a value object passed through
    # several layers is not worth the nicer name.
    Request = Struct.new(:verb, :url, :headers, :body, keyword_init: true)

    # Net::HTTP backend.
    #
    # Connections are cached per (host, port) in fiber-local storage rather than
    # thread-local. Under a fiber scheduler two fibers on one thread run
    # concurrently, and sharing one Net::HTTP object between them interleaves
    # bytes on the socket and corrupts both responses — the same failure that
    # forced Rails to grow a fiber-aware connection pool, arriving here through
    # a completely different door.
    class NetHTTP
      # @param open_timeout [Numeric]
      # @param read_timeout [Numeric]
      # @param write_timeout [Numeric]
      def initialize(open_timeout: 5.0, read_timeout: 30.0, write_timeout: 30.0)
        @open_timeout = open_timeout
        @read_timeout = read_timeout
        @write_timeout = write_timeout
      end

      # @param request [Request]
      # @return [Response]
      def call(request)
        uri = URI.parse(request.url)
        http = connection_for(uri)

        net_request = build_request(request, uri)
        response = http.request(net_request)

        Response.new(
          status: response.code.to_i,
          headers: flatten_headers(response),
          body: response.body
        )
      rescue Net::OpenTimeout, Net::ReadTimeout, Net::WriteTimeout => e
        # A dead route that silently drops packets is indistinguishable from a
        # slow one, so every phase is bounded. Surfaced as a retryable 599.
        Response.new(status: 599, headers: {}, body: "#{e.class}: #{e.message}")
      rescue SystemCallError, OpenSSL::SSL::SSLError, IOError => e
        drop_connection(uri)
        Response.new(status: 599, headers: {}, body: "#{e.class}: #{e.message}")
      end

      # Closes every cached connection held by the current fiber.
      #
      # @return [void]
      def close
        connections.each_value { |http| http.finish if http.started? }
        connections.clear
      end

      private

      def build_request(request, uri)
        klass = case request.verb.to_s.upcase
                when "GET" then Net::HTTP::Get
                when "POST" then Net::HTTP::Post
                when "PATCH" then Net::HTTP::Patch
                when "PUT" then Net::HTTP::Put
                when "DELETE" then Net::HTTP::Delete
                else raise ArgumentError, "unsupported method #{request.verb}"
                end

        net_request = klass.new(uri.request_uri)
        (request.headers || {}).each { |key, value| net_request[key] = value }
        net_request.body = request.body if request.body
        net_request
      end

      def connection_for(uri)
        key = "#{uri.scheme}://#{uri.host}:#{uri.port}"

        cached = connections[key]
        return cached if cached&.started?

        http = Net::HTTP.new(uri.host, uri.port)
        http.use_ssl = uri.scheme == "https"
        http.open_timeout = @open_timeout
        http.read_timeout = @read_timeout
        http.write_timeout = @write_timeout
        http.keep_alive_timeout = 30
        http.start

        connections[key] = http
      end

      def drop_connection(uri)
        key = "#{uri.scheme}://#{uri.host}:#{uri.port}"
        http = connections.delete(key)
        http.finish if http&.started?
      rescue IOError
        # Already closed; nothing to do.
      end

      # Fiber-local, and therefore also thread-local: every thread has a root
      # fiber, so this is strictly narrower than Thread.current storage.
      def connections
        Fiber[:discord_store_connections] ||= {}
      end

      def flatten_headers(response)
        response.each_header.to_h { |key, value| [key.downcase, value] }
      end
    end

    # Builds a multipart/form-data body the way Discord's attachment endpoints
    # expect it: a +payload_json+ part carrying the message, plus one part per
    # file named files[n].
    module Multipart
      module_function

      # @param payload [String] the JSON message payload
      # @param files [Array<Hash>] each {filename:, content:, content_type:}
      # @return [Array(String, String)] content type and body
      def encode(payload, files)
        boundary = "----discordstore#{SecureRandom.hex(16)}"
        body = +""

        body << "--#{boundary}\r\n"
        body << "Content-Disposition: form-data; name=\"payload_json\"\r\n"
        body << "Content-Type: application/json\r\n\r\n"
        body << payload
        body << "\r\n"

        files.each_with_index do |file, index|
          body << "--#{boundary}\r\n"
          body << "Content-Disposition: form-data; name=\"files[#{index}]\"; " \
                  "filename=\"#{sanitize(file[:filename])}\"\r\n"
          body << "Content-Type: #{file[:content_type] || "application/octet-stream"}\r\n\r\n"
          body << file[:content].to_s.dup.force_encoding(Encoding::BINARY)
          body << "\r\n"
        end

        body << "--#{boundary}--\r\n"

        ["multipart/form-data; boundary=#{boundary}", body]
      end

      def sanitize(filename)
        filename.to_s.gsub(/["\r\n\\]/, "_")
      end
    end
  end
end
