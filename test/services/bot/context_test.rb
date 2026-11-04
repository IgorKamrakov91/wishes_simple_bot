require "test_helper"
require "mocha/minitest"
require "telegram/bot"

# Load the gem's types the way real updates do: Message and MaybeInaccessibleMessage
# reference each other, so autoloading CallbackQuery first fails
Telegram::Bot::Types::Update

class BotContextTest < ActiveSupport::TestCase
  setup do
    @api = mock("TelegramApi")
    @bot = mock("TelegramBot")
    @bot.stubs(:api).returns(@api)
    @user = users(:one)
  end

  def callback_context
    callback = Telegram::Bot::Types::CallbackQuery.new(
      id: "1",
      from: { id: 12345, is_bot: false, first_name: "John" },
      chat_instance: "chat",
      data: "show_lists",
      message: { message_id: 42, date: 1, chat: { id: 777, type: "private" }, text: "Old screen" }
    )
    Bot::Context.new(bot: @bot, user: @user, source: callback)
  end

  def response_error(description)
    response = Struct.new(:body, :status).new({ ok: false, error_code: 400, description: description }.to_json, 400)
    Telegram::Bot::Exceptions::ResponseError.new(response: response)
  end

  test "render edits the message a button belongs to" do
    @api.expects(:edit_message_text).with do |params|
      params[:chat_id] == 777 && params[:message_id] == 42 && params[:parse_mode] == "HTML" &&
        params[:link_preview_options].is_disabled
    end
    @api.expects(:send_message).never

    callback_context.render("New screen")
  end

  test "render ignores unchanged screens" do
    @api.stubs(:edit_message_text).raises(response_error("Bad Request: message is not modified"))
    @api.expects(:send_message).never

    callback_context.render("Same screen")
  end

  test "render sends a new message when the old one can't be edited" do
    @api.stubs(:edit_message_text).raises(response_error("Bad Request: message can't be edited"))
    @api.expects(:send_message).with { |params| params[:chat_id] == 777 && params[:text] == "New screen" }

    callback_context.render("New screen")
  end

  test "render sends a new message for commands" do
    message = Telegram::Bot::Types::Message.new(
      message_id: 1, date: 1, chat: { id: 777, type: "private" }, text: "/start",
      from: { id: 12345, is_bot: false, first_name: "John" }
    )
    @api.expects(:send_message).with { |params| params[:chat_id] == 777 && params[:parse_mode] == "HTML" }

    Bot::Context.new(bot: @bot, user: @user, source: message).render("Menu")
  end
end
