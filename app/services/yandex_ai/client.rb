require "net/http"

module YandexAi
  # Chat Completions in Yandex AI Studio. Prompts and answers are never logged,
  # and Yandex is asked not to store them.
  class Client
    class Error < StandardError
      attr_reader :code

      def initialize(code)
        @code = code
        super(code)
      end
    end

    ENDPOINT = URI("https://ai.api.cloud.yandex.net/v1/chat/completions")
    DEFAULT_MODEL = "aliceai-llm-flash"
    OPEN_TIMEOUT = 3
    READ_TIMEOUT = 20
    MAX_RESPONSE_BYTES = 64.kilobytes

    def initialize(api_key: ENV.fetch("YANDEX_AI_API_KEY"), folder_id: ENV.fetch("YANDEX_AI_FOLDER_ID"),
                   model: ENV["YANDEX_AI_MODEL"].presence || DEFAULT_MODEL)
      @api_key = api_key
      @folder_id = folder_id
      @model = model
    end

    # Returns the assistant's text
    def chat(messages, temperature:, max_tokens:, response_format: nil)
      body = { model: "gpt://#{@folder_id}/#{@model}", messages: messages,
               temperature: temperature, max_tokens: max_tokens }
      body[:response_format] = response_format if response_format

      response = post(body)
      raise Error, "http_#{response.code}" unless response.is_a?(Net::HTTPSuccess)
      raise Error, "too_large" if response.body.to_s.bytesize > MAX_RESPONSE_BYTES

      data = JSON.parse(response.body)
      choice = data.dig("choices", 0)
      raise Error, "truncated" if choice&.dig("finish_reason") == "length"

      choice&.dig("message", "content").presence || raise(Error, "empty")
    rescue JSON::ParserError
      raise Error, "bad_json"
    rescue Net::OpenTimeout, Net::ReadTimeout, Net::WriteTimeout
      raise Error, "timeout"
    rescue SocketError, SystemCallError, OpenSSL::SSL::SSLError, IOError
      raise Error, "network"
    end

    private

    def post(body)
      request = Net::HTTP::Post.new(ENDPOINT)
      request["Authorization"] = "Api-Key #{@api_key}"
      request["Content-Type"] = "application/json"
      request["x-folder-id"] = @folder_id
      request["x-data-logging-enabled"] = "false"
      request.body = body.to_json

      response = nil
      Net::HTTP.start(ENDPOINT.host, ENDPOINT.port, use_ssl: true,
                      open_timeout: OPEN_TIMEOUT, read_timeout: READ_TIMEOUT, write_timeout: OPEN_TIMEOUT) do |http|
        response = http.request(request)
      end
      response
    end
  end
end
