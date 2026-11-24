require "net/http"
require "stringio"

module Bot
  # Prepares an image document for Telegram sendPhoto. No model calls. Only a
  # Telegram-owned path is downloaded; bytes and token-bearing URLs stay local.
  class PhotoGiftDocument
    class InvalidImage < StandardError; end

    def initialize(api:, token: ENV.fetch("TELEGRAM_BOT_TOKEN"))
      @api, @token = api, token
    end

    def prepare(draft)
      require "vips"

      file = @api.get_file(file_id: draft.file_id)
      path = file.file_path.to_s
      raise InvalidImage unless path.match?(%r{\A[\w/.-]+\z}) && !path.include?("..")

      bytes = download(URI("https://api.telegram.org/file/bot#{@token}/#{path}"))
      jpeg = bytes.start_with?("\xFF\xD8\xFF".b)
      png = bytes.start_with?("\x89PNG\r\n\x1A\n".b)
      raise InvalidImage unless jpeg || png

      image = Vips::Image.new_from_buffer(bytes, "", access: :sequential)
      raise InvalidImage if image.width * image.height > PhotoGiftIntake::MAX_PIXELS

      image = image.thumbnail_image(2048, height: 2048, size: :down)
      image = image.flatten(background: [ 255, 255, 255 ]) if image.has_alpha?
      output = image.jpegsave_buffer(strip: true, Q: 90)
      raise InvalidImage if output.bytesize > PhotoGiftIntake::MAX_BYTES

      # Uploading a document id as photo is unsupported. The returned photo id
      # is what a saved gift can safely reuse for owners and admitted guests.
      response = @api.send_photo(chat_id: draft.chat_id,
        photo: Faraday::Multipart::FilePart.new(StringIO.new(output), "image/jpeg", "gift.jpg"))
      response.photo.max_by { |photo| photo.width * photo.height }.file_id
    end

    private

    def download(uri)
      bytes = String.new(encoding: Encoding::BINARY)
      Net::HTTP.start(uri.host, uri.port, use_ssl: true, open_timeout: 3, read_timeout: 15, write_timeout: 3) do |http|
        http.request(Net::HTTP::Get.new(uri)) do |response|
          raise InvalidImage unless response.is_a?(Net::HTTPSuccess)
          raise InvalidImage if response["Content-Length"].to_i > PhotoGiftIntake::MAX_BYTES

          response.read_body do |chunk|
            raise InvalidImage if bytes.bytesize + chunk.bytesize > PhotoGiftIntake::MAX_BYTES

            bytes << chunk
          end
        end
      end
      bytes
    end
  end
end
