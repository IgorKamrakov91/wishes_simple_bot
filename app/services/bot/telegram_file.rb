require "net/http"

module Bot
  # Downloads a file a person sent to the bot. The download URL contains the
  # bot token, so neither it nor the file path is ever logged or stored.
  class TelegramFile
    class Error < StandardError; end

    MAX_BYTES = 10.megabytes
    TIMEOUT = 15

    def initialize(token: ENV.fetch("TELEGRAM_BOT_TOKEN"), api: nil)
      @token = token
      @api = api || Telegram::Bot::Client.new(token).api
    end

    def download(file_id, max_bytes: MAX_BYTES)
      file = @api.get_file(file_id: file_id)
      raise Error, "too_large" if file.file_size.to_i > max_bytes
      raise Error, "unavailable" if file.file_path.blank?

      fetch(URI("https://api.telegram.org/file/bot#{@token}/#{file.file_path}"), max_bytes)
    rescue Telegram::Bot::Exceptions::ResponseError, Faraday::Error
      raise Error, "unavailable"
    rescue Net::OpenTimeout, Net::ReadTimeout, SocketError, SystemCallError, OpenSSL::SSL::SSLError, IOError
      raise Error, "network"
    end

    private

    def fetch(uri, max_bytes)
      body = +""
      Net::HTTP.start(uri.host, uri.port, use_ssl: true, open_timeout: TIMEOUT, read_timeout: TIMEOUT) do |http|
        http.request(Net::HTTP::Get.new(uri)) do |response|
          raise Error, "unavailable" unless response.is_a?(Net::HTTPSuccess)

          response.read_body do |chunk|
            body << chunk
            raise Error, "too_large" if body.bytesize > max_bytes
          end
        end
      end
      body
    end
  end
end
