require "test_helper"
require "mocha/minitest"
require "telegram/bot"

# Load the gem's types the way real updates do
Telegram::Bot::Types::Update

# The bot explains what went wrong and never stays silent in a private chat
class BotInputFeedbackTest < ActiveSupport::TestCase
  setup do
    @api = mock("TelegramApi")
    @api.stubs(:answer_callback_query)
    @bot = mock("TelegramBot")
    @bot.stubs(:api).returns(@api)
    @sent = []
    @api.stubs(:send_message).with { |params| @sent << params; true }
    @api.stubs(:edit_message_text).with { |params| @sent << params; true }

    @user = User.create!(telegram_id: 70001, first_name: "Feedback")
    @wishlist = @user.wishlists.create!(title: "Birthday")
    @item = @wishlist.items.create!(title: "Puzzle", price: 10)
  end

  def build_message(text: nil, chat_type: "private", **extra)
    Telegram::Bot::Types::Message.new(
      message_id: 1, date: 1, **{ text: text }.compact, **extra,
      chat: { id: @user.telegram_id, type: chat_type },
      from: { id: @user.telegram_id, is_bot: false, first_name: "Feedback" }
    )
  end

  def press(data)
    Bot::Callbacks.handle(@bot, Telegram::Bot::Types::CallbackQuery.new(
      id: "1", chat_instance: "chat", data: data,
      from: { id: @user.telegram_id, is_bot: false, first_name: "Feedback" },
      message: { message_id: 7, date: 1, chat: { id: @user.telegram_id, type: "private" }, text: "Card" }
    ))
  end

  def say(text = nil, **options)
    Bot::Commands.handle(@bot, build_message(text: text, **options))
  end

  def edit(field)
    @user.update!(bot_state: "editing_item", bot_payload: { "item_id" => @item.id, "field" => field })
  end

  def last_text
    screen_text(@sent.last[:text])
  end

  def widened?
    @sent.last[:text].end_with?("\n#{Bot::Context::SCREEN_WIDTH_LINE}")
  end

  def last_buttons
    @sent.last[:reply_markup].inline_keyboard.flatten
  end

  test "a wrong price is explained and the input stays open with a cancel button" do
    edit("price")
    say("две тыщи")

    assert_equal I18n.t("bot.input_errors.price.not_a_number"), last_text
    assert widened?, "an error with buttons is as wide as the prompt before it"
    assert_equal [ "open_item:#{@item.id}" ], last_buttons.map(&:callback_data)
    assert_equal "editing_item", @user.reload.bot_state
    assert_equal 10, @item.reload.price
  end

  test "prices may carry spaces, a comma and a ruble sign" do
    edit("price")
    say("2 500,50 ₽")

    assert_equal BigDecimal("2500.50"), @item.reload.price
    assert_nil @user.reload.bot_state
  end

  test "a link without a scheme gets https" do
    edit("url")
    say("ozon.ru/t/abc")

    assert_equal "https://ozon.ru/t/abc", @item.reload.url
  end

  test "text that is not a link is refused" do
    edit("url")
    say("в магазине у дома")

    assert_equal I18n.t("bot.input_errors.url.invalid"), last_text
    assert_nil @item.reload.url
    assert_equal "editing_item", @user.reload.bot_state
  end

  test "a too long gift name is refused at the name step" do
    @user.start_adding_item!(wishlist_id: @wishlist.id)
    say("a" * (Item::TITLE_LIMIT + 1))

    assert_equal I18n.t("bot.input_errors.title.too_long", count: Item::TITLE_LIMIT), last_text
    assert_equal "adding_item", @user.reload.bot_state
  end

  test "a too long list name is refused" do
    @user.start_creating_list!
    say("a" * (Wishlist::TITLE_LIMIT + 1))

    assert_equal I18n.t("bot.input_errors.title.too_long", count: Wishlist::TITLE_LIMIT), last_text
    assert_equal [ "show_lists" ], last_buttons.map(&:callback_data)
  end

  test "a photo during input asks for text" do
    @user.start_creating_list!
    say(photo: [ { file_id: "f", file_unique_id: "u", width: 1, height: 1 } ])

    assert_equal I18n.t("bot.input_errors.text_only"), last_text
    assert_equal "creating_list", @user.reload.bot_state
  end

  test "the edit prompt shows the current value and offers to remove it" do
    press("edit_item_field:price:#{@item.id}")

    assert_match I18n.t("bot.input_hints.price"), last_text
    assert_match "#{I18n.t('bot.messages.current_value')}: 10 ₽", last_text
    assert_includes last_buttons.map(&:callback_data), "clear_item_field:price:#{@item.id}"
  end

  test "the name has no remove button" do
    press("edit_item_field:title:#{@item.id}")

    refute last_buttons.any? { |button| button.callback_data.to_s.start_with?("clear_item_field:") }
  end

  test "remove clears an optional value and ends the input" do
    edit("price")
    press("clear_item_field:price:#{@item.id}")

    assert_nil @item.reload.price
    assert_nil @user.reload.bot_state
  end

  test "remove can't clear the name" do
    press("clear_item_field:title:#{@item.id}")

    assert_equal "Puzzle", @item.reload.title
  end

  test "/cancel ends the input and says so" do
    @user.start_creating_list!
    say("/cancel")

    assert_equal I18n.t("bot.commands.cancelled"), last_text
    assert widened?
    assert_nil @user.reload.bot_state
  end

  test "/cancel without input says there is nothing to cancel" do
    say("/cancel")

    assert_equal I18n.t("bot.commands.nothing_to_cancel"), last_text
  end

  test "/new starts a new list" do
    say("/new")

    assert_equal "creating_list", @user.reload.bot_state
    assert_equal I18n.t("bot.messages.enter_list_name"), last_text
  end

  test "plain text outside any input gets a hint and a menu" do
    say("привет")

    assert_equal I18n.t("bot.commands.unrecognized_text"), last_text
    assert_equal %w[show_lists main_menu], last_buttons.map(&:callback_data)
  end

  test "an unknown command lists the commands" do
    say("/foo")

    assert last_text.start_with?(I18n.t("bot.commands.unknown_command"))
    Bot::Profile::COMMANDS.each { |command| assert_includes last_text, "/#{command} — " }
  end

  test "a sticker outside any input gets an answer" do
    say(sticker: { file_id: "s", file_unique_id: "u", type: "regular", width: 1, height: 1, is_animated: false, is_video: false })

    assert_equal I18n.t("bot.commands.text_only"), last_text
  end

  test "messages in groups are not answered" do
    say("привет", chat_type: "group")

    assert_empty @sent
  end
end
