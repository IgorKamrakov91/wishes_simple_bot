require "test_helper"
require "mocha/minitest"
require "telegram/bot"

class BotTelegramFileTest < ActiveSupport::TestCase
  setup do
    @api = stub("api")
    @files = Bot::TelegramFile.new(token: "123:SECRET", api: @api)
  end

  def file(size: 10, path: "photos/file_1.jpg")
    Telegram::Bot::Types::File.new({ file_id: "f", file_unique_id: "u", file_size: size, file_path: path }.compact)
  end

  def serve(*chunks, klass: Net::HTTPOK)
    response = klass.new("1.1", "200", "")
    response.stubs(:read_body).multiple_yields(*chunks.map { |chunk| [ chunk ] })
    http = stub("http")
    http.stubs(:request).yields(response)
    Net::HTTP.expects(:start).with("api.telegram.org", 443, has_entries(use_ssl: true)).yields(http)
  end

  test "downloads the file in pieces" do
    @api.expects(:get_file).with(file_id: "f").returns(file)
    serve("ab", "cd")
    assert_equal "abcd", @files.download("f")
  end

  test "refuses a file over the limit before and while downloading" do
    @api.stubs(:get_file).returns(file(size: 11.megabytes))
    Net::HTTP.expects(:start).never
    assert_equal "too_large", assert_raises(Bot::TelegramFile::Error) { @files.download("f") }.message

    Net::HTTP.unstub(:start)
    @api.stubs(:get_file).returns(file(size: nil))
    serve("x" * 6, "x" * 6)
    assert_equal "too_large", assert_raises(Bot::TelegramFile::Error) { @files.download("f", max_bytes: 10) }.message
  end

  test "errors never carry the token or the file path" do
    @api.stubs(:get_file).raises(Faraday::ConnectionFailed.new("https://api.telegram.org/bot123:SECRET/getFile"))
    error = assert_raises(Bot::TelegramFile::Error) { @files.download("f") }
    assert_equal "unavailable", error.message

    @api.stubs(:get_file).returns(file)
    Net::HTTP.stubs(:start).raises(Net::ReadTimeout)
    assert_equal "network", assert_raises(Bot::TelegramFile::Error) { @files.download("f") }.message

    Net::HTTP.unstub(:start)
    serve("nope", klass: Net::HTTPNotFound)
    error = assert_raises(Bot::TelegramFile::Error) { @files.download("f") }
    assert_equal "unavailable", error.message
    refute_includes error.message, "SECRET"
  end
end
