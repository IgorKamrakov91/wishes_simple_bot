require "test_helper"
require "mocha/minitest"

class TelegramControllerTest < ActionDispatch::IntegrationTest
  setup do
    @previous_token = ENV["TELEGRAM_BOT_TOKEN"]
    @previous_secret = ENV["TELEGRAM_WEBHOOK_SECRET"]
    ENV["TELEGRAM_BOT_TOKEN"] = "123:test-token"
    ENV.delete("TELEGRAM_WEBHOOK_SECRET")
  end

  teardown do
    ENV["TELEGRAM_BOT_TOKEN"] = @previous_token
    ENV["TELEGRAM_WEBHOOK_SECRET"] = @previous_secret
  end

  test "dispatches a valid Telegram update" do
    bot = mock("TelegramBot")
    Telegram::Bot::Client.stubs(:run).yields(bot)
    Bot::Dispatcher.expects(:dispatch).with(bot, instance_of(Telegram::Bot::Types::Update))

    post "/telegram/webhook", params: { update_id: 123_456 }, as: :json, headers: secret_header

    assert_response :success
  end

  test "rejects malformed webhook payloads without dispatching" do
    Bot::Dispatcher.expects(:dispatch).never

    post "/telegram/webhook", params: "{not-json", headers: secret_header.merge("CONTENT_TYPE" => "application/json")

    assert_response :bad_request
  end

  test "rejects updates without the secret token" do
    Bot::Dispatcher.expects(:dispatch).never

    post "/telegram/webhook", params: { update_id: 1 }, as: :json

    assert_response :unauthorized
  end

  test "rejects updates with a wrong secret token" do
    Bot::Dispatcher.expects(:dispatch).never

    post "/telegram/webhook", params: { update_id: 1 }, as: :json,
                              headers: { Bot::Webhook::SECRET_HEADER => "forged" }

    assert_response :unauthorized
  end

  test "an explicit secret replaces the derived one" do
    derived_header = secret_header
    ENV["TELEGRAM_WEBHOOK_SECRET"] = "explicit-secret"
    Telegram::Bot::Client.stubs(:run).yields(mock("TelegramBot"))
    Bot::Dispatcher.stubs(:dispatch)

    post "/telegram/webhook", params: { update_id: 1 }, as: :json, headers: derived_header
    assert_response :unauthorized

    post "/telegram/webhook", params: { update_id: 1 }, as: :json,
                              headers: { Bot::Webhook::SECRET_HEADER => "explicit-secret" }
    assert_response :success
  end

  test "rejects everything when no secret can be built" do
    ENV.delete("TELEGRAM_BOT_TOKEN")
    Bot::Dispatcher.expects(:dispatch).never

    post "/telegram/webhook", params: { update_id: 1 }, as: :json,
                              headers: { Bot::Webhook::SECRET_HEADER => "" }

    assert_response :unauthorized
  end

  private

  def secret_header
    { Bot::Webhook::SECRET_HEADER => Bot::Webhook.secret }
  end
end
