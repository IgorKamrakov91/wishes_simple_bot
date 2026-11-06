require "test_helper"
require "mocha/minitest"
require "telegram/bot"

# Load the gem's types the way real updates do: Message and MaybeInaccessibleMessage
# reference each other, so autoloading CallbackQuery first fails
Telegram::Bot::Types::Update

class BotContextTest < ActiveSupport::TestCase
  include Bot::Helpers

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

  def keyboard
    build_keyboard([ [ inline_btn("Back", "main_menu") ] ])
  end

  def message_context
    message = Telegram::Bot::Types::Message.new(
      message_id: 1, date: 1, chat: { id: 777, type: "private" }, text: "/cancel",
      from: { id: 12345, is_bot: false, first_name: "John" }
    )
    Bot::Context.new(bot: @bot, user: @user, source: message)
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

  test "screens with buttons get a blank line that keeps them wide, plain messages don't" do
    sent = []
    @api.stubs(:edit_message_text).with { |params| sent << params[:text]; true }

    callback_context.render("Menu", keyboard)
    callback_context.render("Done")
    callback_context.edit_message("Plain edit", keyboard)

    pad = "\n#{"\u2800" * 23}"
    assert_equal [ "Menu#{pad}", "Done", "Plain edit#{pad}" ], sent
    assert_equal "Menu", screen_text(sent.first)
  end

  test "the blank line is left out when it would push a screen past Telegram's limit" do
    sent = []
    @api.stubs(:edit_message_text).with { |params| sent << params[:text]; true }
    room = 4096 - 24

    callback_context.render("x" * room, keyboard)
    callback_context.render("x" * (room + 1), keyboard)
    callback_context.render("x" * 4096, keyboard)
    # An emoji is two UTF-16 units for Telegram
    callback_context.render("😂" + "x" * (room - 1), keyboard)

    assert_equal [ 4096, room + 1, 4096, room + 1 ], sent.map { |text| text.encode("UTF-16LE").bytesize / 2 }
    assert_equal [ true, false, false, false ], sent.map { |text| text.end_with?(Bot::Context::SCREEN_WIDTH_LINE) }
  end

  test "a command reply with buttons is widened too" do
    @api.expects(:send_message).with { |params| params[:text] == "Cancelled\n#{Bot::Context::SCREEN_WIDTH_LINE}" }

    message_context.send_text("Cancelled", keyboard)
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
