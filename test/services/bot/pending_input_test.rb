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

    Bot::Commands.handle(@bot, text_message("Puzzle"))

    assert_equal "adding_item_url", @user.reload.bot_state
    assert_equal "Puzzle", @user.bot_payload["title"]
  end

  test "a gift is not published before its link step is finished" do
    @user.start_adding_item!(wishlist_id: @wishlist.id)
    @api.stubs(:send_message)

    assert_no_difference("Item.count") do
      Bot::Commands.handle(@bot, text_message("Puzzle"))
    end
  end

  test "cancelling at the link step publishes nothing" do
    start_draft("Puzzle")
    Bot::Callbacks::WishlistHandler.any_instance.expects(:open_list).with(@wishlist.id)

    assert_no_difference("Item.count") do
      Bot::Callbacks.handle(@bot, callback("open_list:#{@wishlist.id}"))
    end
    assert_nil @user.reload.bot_state
  end

  test "a link finishes the draft" do
    start_draft("Puzzle")
    @api.stubs(:send_message)

    assert_difference("Item.count", 1) do
      Bot::Commands.handle(@bot, text_message("https://example.com/puzzle"))
    end
    item = @wishlist.items.last
    assert_equal [ "Puzzle", "https://example.com/puzzle" ], [ item.title, item.url ]
    assert_nil @user.reload.bot_state
  end

  test "the link prompt names the gift and the list" do
    @user.start_adding_item!(wishlist_id: @wishlist.id)
    @api.expects(:send_message).with do |params|
      buttons = params[:reply_markup].inline_keyboard.flatten
      params[:text].include?("«Puzzle &amp; co»") && params[:text].include?("«Birthday»") &&
        buttons.map(&:callback_data) == [ "skip_item_url:#{@user.reload.bot_payload['draft_id']}", "open_list:#{@wishlist.id}" ]
    end

    Bot::Commands.handle(@bot, text_message("Puzzle & co"))
  end

  test "a list deleted while typing ends the input with an explanation" do
    start_draft("Puzzle")
    @wishlist.destroy!
    @api.expects(:send_message).with { |params| screen_text(params[:text]) == I18n.t("bot.messages.input_target_gone") }

    assert_no_difference("Item.count") do
      Bot::Commands.handle(@bot, text_message("https://example.com/puzzle"))
    end
    assert_nil @user.reload.bot_state
  end

  test "the page counter button keeps the pending input" do
    start_draft("Puzzle")

    Bot::Callbacks.handle(@bot, callback("noop"))

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
      screen_text(params[:text]) == [ I18n.t("bot.messages.list_context", list: "Birthday"), I18n.t("bot.messages.enter_item_name") ].join("\n") &&
        button.text == I18n.t("bot.buttons.cancel") && button.callback_data == "open_list:#{@wishlist.id}"
    end

    Bot::Callbacks.handle(@bot, callback("add_item:#{@wishlist.id}"))

    assert_equal "adding_item", @user.reload.bot_state
  end

  test "skip saves the draft without a link" do
    draft_id = start_draft("Puzzle")
    @api.expects(:edit_message_text).with { |params| screen_text(params[:text]) == I18n.t("bot.messages.item_added", title: "Puzzle", list: "Birthday") }

    assert_difference("Item.count", 1) do
      Bot::Callbacks.handle(@bot, callback("skip_item_url:#{draft_id}"))
    end
    assert_nil @wishlist.items.last.url
    assert_nil @user.reload.bot_state
  end

  test "skip still finishes a gift started before drafts" do
    item = @wishlist.items.create!(title: "Puzzle", url: nil)
    @user.update!(bot_state: "adding_item_url", bot_payload: { "item_id" => item.id, "wishlist_id" => @wishlist.id })
    @api.expects(:edit_message_text).with { |params| screen_text(params[:text]) == I18n.t("bot.messages.item_added", title: "Puzzle", list: "Birthday") }

    Bot::Callbacks.handle(@bot, callback("skip_item_url"))

    assert_nil item.reload.url
    assert_nil @user.reload.bot_state
  end

  test "a draft id made only of digits still matches its button" do
    @user.start_adding_item!(wishlist_id: @wishlist.id)
    @api.stubs(:send_message)
    SecureRandom.stubs(:hex).returns("12345678")
    Bot::Commands.handle(@bot, text_message("Puzzle"))
    SecureRandom.unstub(:hex)
    draft_id = @user.reload.bot_payload["draft_id"]
    @api.stubs(:edit_message_text)

    assert_difference("Item.count", 1) do
      Bot::Callbacks.handle(@bot, callback("skip_item_url:#{draft_id}"))
    end
  end

  test "pressing skip twice saves the gift once" do
    draft_id = start_draft("Puzzle")
    @api.stubs(:edit_message_text)

    assert_difference("Item.count", 1) do
      2.times { Bot::Callbacks.handle(@bot, callback("skip_item_url:#{draft_id}")) }
    end
  end

  test "a stale skip button does nothing" do
    @api.expects(:edit_message_text).never
    @api.expects(:send_message).never
    @api.expects(:answer_callback_query).with(callback_query_id: "1", text: I18n.t("bot.messages.button_outdated"))

    Bot::Callbacks.handle(@bot, callback("skip_item_url:abc123"))
  end

  test "a skip button from an earlier gift doesn't save the current one" do
    start_draft("Puzzle")
    @api.expects(:edit_message_text).never

    assert_no_difference("Item.count") do
      Bot::Callbacks.handle(@bot, callback("skip_item_url:olddraft"))
    end
    assert_equal "adding_item_url", @user.reload.bot_state
  end

  private

  def start_draft(title)
    draft_id = "d#{SecureRandom.hex(3)}"
    @user.update!(bot_state: "adding_item_url",
                  bot_payload: { "wishlist_id" => @wishlist.id, "title" => title, "draft_id" => draft_id })
    draft_id
  end
end
