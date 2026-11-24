require "test_helper"
require "mocha/minitest"
require "vips"

class BotPhotoGiftDocumentTest < ActiveSupport::TestCase
  setup do
    @api = mock("Telegram API")
    @processor = Bot::PhotoGiftDocument.new(api: @api, token: "test-token")
    @draft = stub(file_id: "document-id", chat_id: 97921, locale: "ru")
    @api.stubs(:get_file).with(file_id: "document-id").returns(stub(file_path: "documents/file.png"))
  end

  test "a real PNG is resized and uploaded as JPEG and the reusable photo id is returned" do
    png = Vips::Image.black(3000, 100).pngsave_buffer
    @processor.stubs(:download).returns(png)
    @api.expects(:send_photo).with do |params|
      part = params[:photo]
      converted = Vips::Image.new_from_buffer(part.io.read, "")
      assert_equal 2048, converted.width
      assert_operator converted.height, :>, 0
      assert_equal "image/jpeg", part.content_type
      assert_equal 97921, params[:chat_id]
      assert_equal "Фото для подарка", params[:caption]
      true
    end.returns(stub(photo: [ stub(width: 100, height: 10, file_id: "small"), stub(width: 2048, height: 68, file_id: "photo-id") ]))
    assert_equal "photo-id", @processor.prepare(@draft)
  end

  test "an RGBA PNG is flattened into a usable JPEG" do
    @processor.stubs(:download).returns(Vips::Image.black(20, 20, bands: 4).copy(interpretation: :srgb).pngsave_buffer)
    @api.expects(:send_photo).with do |params|
      image = Vips::Image.new_from_buffer(params[:photo].io.read, "")
      assert_equal 3, image.bands
      true
    end.returns(stub(photo: [ stub(width: 20, height: 20, file_id: "photo") ]))
    assert_equal "photo", @processor.prepare(@draft)
  end

  test "a full-resolution phone JPEG is accepted and downsized with an English caption" do
    @draft.stubs(:locale).returns("en")
    jpeg = Vips::Image.black(8064, 6048, bands: 3).jpegsave_buffer
    @processor.stubs(:download).returns(jpeg)
    @api.expects(:send_photo).with do |params|
      image = Vips::Image.new_from_buffer(params[:photo].io.read, "")
      assert_equal [ 2048, 1536 ], [ image.width, image.height ]
      assert_equal "Photo for your gift", params[:caption]
      true
    end.returns(stub(photo: [ stub(width: 2048, height: 1536, file_id: "phone-photo") ]))
    assert_equal "phone-photo", @processor.prepare(@draft)
  end

  test "a forged image and excessive decoded pixels are rejected before upload" do
    @api.expects(:send_photo).never
    @processor.stubs(:download).returns("<html>not a PNG</html>")
    assert_raises(Bot::PhotoGiftDocument::InvalidImage) { @processor.prepare(@draft) }
    @processor.stubs(:download).returns(Vips::Image.black(10_001, 10_000).pngsave_buffer)
    assert_raises(Bot::PhotoGiftDocument::InvalidImage) { @processor.prepare(@draft) }
  end

  test "paths cannot escape the Telegram download prefix" do
    @api.stubs(:get_file).returns(stub(file_path: "https://attacker.example/picture"))
    @processor.expects(:download).never
    assert_raises(Bot::PhotoGiftDocument::InvalidImage) { @processor.prepare(@draft) }
  end

  test "download stops when streamed bytes exceed the limit even without a length header" do
    response = Net::HTTPOK.new("1.1", "200", "OK")
    response.stubs(:read_body).multiple_yields([ "x" * Bot::PhotoGiftIntake::MAX_BYTES ], [ "x" ])
    http = stub
    http.stubs(:request).yields(response)
    Net::HTTP.stubs(:start).yields(http)
    assert_raises(Bot::PhotoGiftDocument::InvalidImage) do
      @processor.send(:download, URI("https://api.telegram.org/file/test"))
    end
  end
end
