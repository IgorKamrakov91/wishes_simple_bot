require "test_helper"

class ImageShrinkerTest < ActiveSupport::TestCase
  setup { skip "libvips is not installed" unless ImageShrinker.available? }

  test "shrinks a large picture to a JPEG within the limit" do
    png = Vips::Image.black(3000, 1500).add(120).cast(:uchar).pngsave_buffer
    jpeg = ImageShrinker.call(png, max_side: 2048, max_pixels: 40_000_000)
    image = Vips::Image.new_from_buffer(jpeg, "")
    assert_equal [ 2048, 1024 ], [ image.width, image.height ]
    assert_equal "jpegload_buffer", image.get("vips-loader")
  end

  test "keeps small pictures small and refuses huge or broken ones" do
    png = Vips::Image.black(800, 600).cast(:uchar).pngsave_buffer
    image = Vips::Image.new_from_buffer(ImageShrinker.call(png, max_side: 2048, max_pixels: 40_000_000), "")
    assert_equal [ 800, 600 ], [ image.width, image.height ]

    error = assert_raises(YandexAi::Client::Error) { ImageShrinker.call(png, max_side: 2048, max_pixels: 1000) }
    assert_equal "too_large", error.code
    error = assert_raises(YandexAi::Client::Error) { ImageShrinker.call("\xFF\xD8\xFFbroken".b, max_side: 2048, max_pixels: 1000) }
    assert_equal "not_an_image", error.code
  end
end
