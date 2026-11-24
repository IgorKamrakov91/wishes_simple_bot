# Shrinks a picture to a JPEG no larger than max_side on either side, applying
# its rotation and dropping metadata (location, camera). Returns nil when
# libvips isn't installed; raises YandexAi::Client::Error for bad pictures.
module ImageShrinker
  QUALITY = 85

  def self.available?
    return @available unless @available.nil?

    @available = begin
      require "vips"
      true
    rescue LoadError
      false
    end
  end

  def self.call(bytes, max_side:, max_pixels:)
    return unless available?

    # The header is read without decoding, so a huge picture is refused cheaply
    header = Vips::Image.new_from_buffer(bytes, "")
    raise YandexAi::Client::Error, "too_large" if header.width * header.height > max_pixels

    Vips::Image.thumbnail_buffer(bytes, max_side, height: max_side, size: :down)
      .jpegsave_buffer(Q: QUALITY, strip: true)
  rescue Vips::Error
    raise YandexAi::Client::Error, "not_an_image"
  end
end
