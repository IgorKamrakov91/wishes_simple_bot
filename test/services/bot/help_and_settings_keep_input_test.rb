require "test_helper"
require "mocha/minitest"
require "telegram/bot"

# Load the gem's types the way real updates do
Telegram::Bot::Types::Update

# Help and settings are lookups: they keep what the user is typing, and the
# user can carry on or cancel from there
class BotHelpAndSettingsKeepInputTest < ActiveSupport::TestCase
  setup do
    @api = mock("TelegramApi")
    @answers = []
    @api.stubs(:answer_callback_query).with { |params| @answers << params; true }
    @bot = mock("TelegramBot")
    @bot.stubs(:api).returns(@api)
    @sent = []
    @api.stubs(:send_message).with { |params| @sent << params; true }
    @api.stubs(:edit_message_text).with { |params| @sent << params; true }

    @user = User.create!(telegram_id: 71001, first_name: "Keeper")
    @wishlist = @user.wishlists.create!(title: "Birthday")
  end

  test "a gift draft survives /help and continues where it stopped" do
    press("add_item:#{@wishlist.id}")
    say("Puzzle")
    draft = @user.reload.bot_payload

    say("/help")
    assert_includes last_text, I18n.t("bot.commands.input_active")
    assert_includes last_text, "/settings — настройки"
    assert_equal %w[resume_input cancel_input main_menu settings], last_buttons.map(&:callback_data)
    assert_equal draft, @user.reload.bot_payload

    press("resume_input")
    assert_includes last_text, "«Puzzle»"
    assert_equal [ "skip_item_url:#{draft['draft_id']}", "open_list:#{@wishlist.id}" ], last_buttons.map(&:callback_data)

    say("ozon.ru/t/abc")
    item = @wishlist.items.sole
    assert_equal [ "Puzzle", "https://ozon.ru/t/abc" ], [ item.title, item.url ]
    assert_nil @user.reload.bot_state
  end

  test "settings keep the input, toggles too, and the help button opens help" do
    press("new_list")

    say("/settings")
    assert_includes last_text, I18n.t("bot.commands.input_active")
    press("set_setting:notify_own_reservations:0")
    refute @user.reload.notify_own_reservations
    assert_equal "creating_list", @user.bot_state
    assert_includes last_buttons.map(&:callback_data), "resume_input"

    press("help")
    assert_equal "creating_list", @user.reload.bot_state

    say("Новый год")
    assert_equal [ "Birthday", "Новый год" ], @user.wishlists.order(:id).pluck(:title)
  end

  test "an item edit can be resumed from settings opened by the button" do
    item = @wishlist.items.create!(title: "Puzzle", price: 10)
    press("edit_item_field:price:#{item.id}")
    press("settings")
    press("resume_input")

    assert_match(/\AВведи новое значение поля «Цена»/, last_text)
    say("20")
    assert_equal 20, item.reload.price
  end

  test "cancel from help ends the input and an old continue button brings nothing back" do
    press("add_item:#{@wishlist.id}")
    say("Puzzle")
    say("/help")

    press("cancel_input")
    assert_nil @user.reload.bot_state
    assert_equal I18n.t("bot.commands.cancelled"), @answers.last[:text]

    press("resume_input")
    assert_nil @user.reload.bot_state
    assert_equal I18n.t("bot.commands.input_finished"), @answers.last[:text]
    assert_empty @wishlist.items
  end

  test "without input help and settings show no input buttons" do
    say("/help")
    refute_includes last_text, I18n.t("bot.commands.input_active")
    assert_equal %w[main_menu settings], last_buttons.map(&:callback_data)

    say("/settings")
    refute_includes last_buttons.map(&:callback_data), "resume_input"
  end

  test "an unknown command keeps a gift draft and offers to continue" do
    press("add_item:#{@wishlist.id}")
    say("Puzzle")
    draft = @user.reload.bot_payload

    say("/hlep")

    assert_includes last_text, I18n.t("bot.commands.unknown_command")
    assert_includes last_text, I18n.t("bot.commands.input_active")
    assert_equal %w[resume_input cancel_input show_lists main_menu], last_buttons.map(&:callback_data)
    assert_equal "adding_item_url", @user.reload.bot_state
    assert_equal draft, @user.bot_payload
    assert_empty @wishlist.items

    press("resume_input")
    assert_includes last_text, "«Puzzle»"
    say("ozon.ru/t/abc")

    assert_equal [ "Puzzle", "https://ozon.ru/t/abc" ], @wishlist.items.sole.attributes.values_at("title", "url")
    assert_nil @user.reload.bot_state
  end

  test "an unknown command keeps an item edit ready for the next answer" do
    item = @wishlist.items.create!(title: "Puzzle", price: 10)
    press("edit_item_field:price:#{item.id}")
    payload = @user.reload.bot_payload

    say("/setings")

    assert_equal "editing_item", @user.reload.bot_state
    assert_equal payload, @user.bot_payload
    assert_equal 10, item.reload.price

    say("20")
    assert_equal 20, item.reload.price
    assert_nil @user.reload.bot_state
  end

  test "an input preserved after an unknown command can still be cancelled" do
    press("new_list")
    say("/unknown")
    say("/cancel")

    assert_nil @user.reload.bot_state
    assert_nil @user.bot_payload
    assert_equal I18n.t("bot.commands.cancelled"), screen_text(last_text)
    refute_includes last_buttons.map(&:callback_data), "resume_input"
    assert_equal [ "Birthday" ], @user.wishlists.pluck(:title)
  end

  test "other commands still abandon the input" do
    press("new_list")
    say("/reservations")

    assert_nil @user.reload.bot_state
    assert_includes last_text, I18n.t("bot.screens.reservations.title")
  end

  test "the main menu has settings and help side by side" do
    @user.wishlists.first.items.create!(title: "Puzzle")
    say("/start")

    rows = @sent.last[:reply_markup].inline_keyboard.map { |row| row.map(&:callback_data) }
    assert_includes rows, [ "show_reservations", "settings", "help" ]
  end

  test "the main menu counts reservations still to buy" do
    owner = User.create!(telegram_id: 71002, first_name: "Friend")
    list = owner.wishlists.create!(title: "Party")
    list.admit!(@user)
    bought, pending = list.items.create!(title: "Puzzle"), list.items.create!(title: "Book")
    [ bought, pending ].each { |item| item.reserve_for!(@user) }
    bought.update!(purchased_at: Time.current)

    say("/start")

    assert_includes last_text, I18n.t("bot.screens.main.reservations_unbought", number: 2, unbought: 1)
  end

  private

  def say(text)
    Bot::Commands.handle(@bot, Telegram::Bot::Types::Message.new(
      message_id: 1, date: 1, text: text,
      chat: { id: @user.telegram_id, type: "private" },
      from: { id: @user.telegram_id, is_bot: false, first_name: "Keeper" }
    ))
  end

  def press(data)
    Bot::Callbacks.handle(@bot, Telegram::Bot::Types::CallbackQuery.new(
      id: "1", chat_instance: "chat", data: data,
      from: { id: @user.telegram_id, is_bot: false, first_name: "Keeper" },
      message: { message_id: 7, date: 1, chat: { id: @user.telegram_id, type: "private" }, text: "Screen" }
    ))
  end

  def last_text
    @sent.last[:text]
  end

  def last_buttons
    @sent.last[:reply_markup].inline_keyboard.flatten
  end
end
