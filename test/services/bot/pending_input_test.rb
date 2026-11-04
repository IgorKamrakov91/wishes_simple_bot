require "test_helper"
require "mocha/minitest"
require "telegram/bot"

# Load the gem's types the way real updates do: Message and MaybeInaccessibleMessage
# reference each other, so autoloading CallbackQuery first fails
Telegram::Bot::Types::Update

class BotPendingInputTest < ActiveSupport::TestCase
  setup do
    @api = mock("TelegramApi")
    @api.stubs(:answer_callback_query)
    @bot = mock("TelegramBot")
    @bot.stubs(:api).returns(@api)

    @user = User.create!(telegram_id: 40001, first_name: "Pending")
    @wishlist = @user.wishlists.create!(title: "Birthday")
  end

  def text_message(text)
    Telegram::Bot::Types::Message.new(
      message_id: 1, date: 1, text: text,
      chat: { id: @user.telegram_id, type: "private" },
      from: { id: @user.telegram_id, is_bot: false, first_name: "Pending" }
    )
  end

  def callback(data)
    Telegram::Bot::Types::CallbackQuery.new(
      id: "1", chat_instance: "chat", data: data,
      from: { id: @user.telegram_id, is_bot: false, first_name: "Pending" },
      message: { message_id: 7, date: 1, chat: { id: @user.telegram_id, type: "private" }, text: "Prompt" }
    )
  end

  test "a command abandons the pending input instead of becoming its value" do
    @user.start_adding_item!(wishlist_id: @wishlist.id)
    Bot::Callbacks::WishlistHandler.any_instance.expects(:main_menu)

    assert_no_difference("Item.count") do
      Bot::Commands.handle(@bot, text_message("/start"))
    end
    assert_nil @user.reload.bot_state
  end

  test "plain text still answers the pending input" do
    @user.start_adding_item!(wishlist_id: @wishlist.id)
    @api.stubs(:send_message)

    assert_difference("Item.count", 1) do
      Bot::Commands.handle(@bot, text_message("Puzzle"))
    end
    assert_equal "adding_item_url", @user.reload.bot_state
  end

  test "pressing a button abandons the pending input" do
    @user.start_creating_list!
    Bot::Callbacks::WishlistHandler.any_instance.expects(:show_lists)

    Bot::Callbacks.handle(@bot, callback("show_lists"))

    assert_nil @user.reload.bot_state
  end

  test "prompts offer a cancel button back to where the user was" do
    @api.expects(:edit_message_text).with do |params|
      button = params[:reply_markup].inline_keyboard.first.first
      params[:text] == I18n.t("bot.messages.enter_item_name") &&
        button.text == I18n.t("bot.buttons.cancel") && button.callback_data == "open_list:#{@wishlist.id}"
    end

    Bot::Callbacks.handle(@bot, callback("add_item:#{@wishlist.id}"))

    assert_equal "adding_item", @user.reload.bot_state
  end

  test "skip finishes adding a gift without a link" do
    item = @wishlist.items.create!(title: "Puzzle", url: nil)
    @user.update!(bot_state: "adding_item_url", bot_payload: { "item_id" => item.id, "wishlist_id" => @wishlist.id })
    @api.expects(:edit_message_text).with { |params| params[:text] == I18n.t("bot.messages.item_added") }

    Bot::Callbacks.handle(@bot, callback("skip_item_url"))

    assert_nil item.reload.url
    assert_nil @user.reload.bot_state
  end

  test "a stale skip button does nothing" do
    @api.expects(:edit_message_text).never
    @api.expects(:send_message).never

    Bot::Callbacks.handle(@bot, callback("skip_item_url"))
  end
end
