require "test_helper"
require "mocha/minitest"
require "telegram/bot"

Telegram::Bot::Types::Update

class BotCallbackErrorLogsTest < ActiveSupport::TestCase
  setup do
    @output = StringIO.new
    @previous_logger = Rails.logger
    Rails.logger = ActiveSupport::Logger.new(@output)
    @user = User.create!(telegram_id: 98001, first_name: "Owner")
    @api = mock("TelegramApi")
    @bot = stub(api: @api)
    @callback = Telegram::Bot::Types::CallbackQuery.new(
      id: "callback-error", chat_instance: "chat", data: "main_menu",
      from: { id: @user.telegram_id, is_bot: false, first_name: "Owner" },
      message: { message_id: 1, date: 1, chat: { id: @user.telegram_id, type: "private" } }
    )
  end

  teardown do
    Rails.logger = @previous_logger
  end

  test "missing callback targets log the error kind but not private exception contents" do
    Bot::Callbacks::WishlistHandler.any_instance.stubs(:main_menu)
      .raises(ActiveRecord::RecordNotFound, "PrivateGift123 invitation SecretInvite123")
    @api.expects(:answer_callback_query).with(
      callback_query_id: @callback.id, text: I18n.t("bot.messages.not_available"), show_alert: true
    )

    Bot::Callbacks.handle(@bot, @callback)

    assert_includes @output.string, "ActiveRecord::RecordNotFound"
    refute_includes @output.string, "PrivateGift123"
    refute_includes @output.string, "SecretInvite123"
  end

  test "unexpected callback errors omit exception messages and backtraces while keeping the error alert" do
    error = RuntimeError.new("PrivateGift123 SecretInvite123")
    error.set_backtrace([ "private/SecretTrace123.rb:1" ])
    Bot::Callbacks::WishlistHandler.any_instance.stubs(:main_menu).raises(error)
    @api.expects(:answer_callback_query).with(
      callback_query_id: @callback.id, text: I18n.t("bot.messages.error"), show_alert: true
    )

    Bot::Callbacks.handle(@bot, @callback)

    assert_includes @output.string, "RuntimeError"
    %w[PrivateGift123 SecretInvite123 SecretTrace123].each do |private_value|
      refute_includes @output.string, private_value
    end
  end

  test "failed callback answers do not log private request data" do
    Bot::Callbacks::WishlistHandler.any_instance.stubs(:main_menu)
    @api.expects(:answer_callback_query).raises(Faraday::ConnectionFailed, "https://example.com/SecretRequest123")

    Bot::Callbacks.handle(@bot, @callback)

    assert_includes @output.string, "Faraday::ConnectionFailed"
    refute_includes @output.string, "SecretRequest123"
  end
end
