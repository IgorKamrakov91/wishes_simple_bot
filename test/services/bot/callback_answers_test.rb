require "test_helper"
require "mocha/minitest"
require "telegram/bot"

# Load the gem's types the way real updates do
Telegram::Bot::Types::Update

class BotCallbackAnswersTest < ActiveSupport::TestCase
  setup do
    @user = User.create!(telegram_id: 61001, first_name: "Igor")
    @api = mock("TelegramApi")
    @bot = mock("TelegramBot")
    @bot.stubs(:api).returns(@api)
  end

  def callback(data)
    Telegram::Bot::Types::CallbackQuery.new(
      id: "1", chat_instance: "chat", data: data,
      from: { id: @user.telegram_id, is_bot: false, first_name: "Igor" },
      message: { message_id: 7, date: 1, chat: { id: @user.telegram_id, type: "private" }, text: "Menu" }
    )
  end

  def stale_query_error
    response = stub(status: 400, body: { description: "Bad Request: query is too old and response timeout expired or query ID is invalid" }.to_json)
    Telegram::Bot::Exceptions::ResponseError.new(response: response)
  end

  test "a repeated update whose callback can't be answered shows no error" do
    @api.stubs(:edit_message_text)
    @api.expects(:answer_callback_query).raises(stale_query_error)
    @api.expects(:send_message).never

    Bot::Callbacks.handle(@bot, callback("main_menu"))
  end

  test "a failing button answers with a popup instead of a chat message" do
    Bot::Callbacks::WishlistHandler.any_instance.stubs(:main_menu).raises(StandardError, "boom")
    @api.expects(:send_message).never
    @api.expects(:answer_callback_query).with(callback_query_id: "1", text: I18n.t("bot.messages.error"), show_alert: true)

    Bot::Callbacks.handle(@bot, callback("main_menu"))
  end

  test "a deleted list answers with a popup" do
    @api.expects(:send_message).never
    @api.expects(:answer_callback_query).with(callback_query_id: "1", text: I18n.t("bot.messages.not_available"), show_alert: true)

    Bot::Callbacks.handle(@bot, callback("open_list:0"))
  end
end
