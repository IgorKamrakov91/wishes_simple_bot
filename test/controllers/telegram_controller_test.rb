require "test_helper"
require "mocha/minitest"

class TelegramControllerTest < ActionDispatch::IntegrationTest
  test "dispatches a valid Telegram update" do
    bot = mock("TelegramBot")
    Telegram::Bot::Client.stubs(:run).yields(bot)
    Bot::Dispatcher.expects(:dispatch).with(bot, instance_of(Telegram::Bot::Types::Update))

    post "/telegram/webhook", params: { update_id: 123_456 }, as: :json

    assert_response :success
  end

  test "rejects malformed webhook payloads without dispatching" do
    Bot::Dispatcher.expects(:dispatch).never

    post "/telegram/webhook", params: "{not-json", headers: { "CONTENT_TYPE" => "application/json" }

    assert_response :bad_request
  end
end
