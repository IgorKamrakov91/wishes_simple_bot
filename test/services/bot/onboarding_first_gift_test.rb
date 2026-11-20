require "test_helper"
require "mocha/minitest"
require "telegram/bot"

Telegram::Bot::Types::Update

# A newcomer gets to a first saved gift without typing a list name and
# without the link step, then is offered to send the list to a friend
class BotOnboardingFirstGiftTest < ActiveSupport::TestCase
  setup do
    @user = User.create!(telegram_id: 99501, first_name: "New")
    @api = mock("TelegramApi")
    @api.stubs(:answer_callback_query).with { |params| @answer = params; true }
    @bot = stub(api: @api)
    @screens = []
    @api.stubs(:send_message).with { |params| @screens << params; true }
    @api.stubs(:edit_message_text).with { |params| @screens << params; true }
    @message_id = 100
  end

  test "the welcome is short and leads to list name buttons" do
    say("/start")
    assert_includes screen[:text], "Собери список желаний"
    assert_equal [ "new_list" ], callbacks

    press("new_list")
    assert_equal "creating_list", @user.reload.bot_state
    assert_equal Bot::ListPresets.ordered.map { |key| "quick_list:#{key}" } + [ "show_lists" ], callbacks
  end

  test "New Year comes first in season, Birthday the rest of the year" do
    assert_equal "new_year", Bot::ListPresets.ordered(Date.new(2026, 11, 20)).first
    assert_equal "new_year", Bot::ListPresets.ordered(Date.new(2027, 1, 10)).first
    assert_equal "birthday", Bot::ListPresets.ordered(Date.new(2027, 3, 1)).first
  end

  test "a list name button creates the list once and asks for the first gift" do
    press("new_list")

    assert_difference("Wishlist.count", 1) do
      press("quick_list:new_year")
      press("quick_list:new_year")
    end
    list = @user.wishlists.last
    assert_equal "Новый год", list.title
    assert_equal({ "wishlist_id" => list.id, "first_item" => true }, @user.reload.bot_payload)
    assert_includes screen[:text], "Напиши, что хочешь получить"
    assert_equal I18n.t("bot.messages.button_outdated"), @answer[:text]
  end

  test "a list name button does nothing after the input was cancelled" do
    press("new_list")
    say("/cancel")

    assert_no_difference("Wishlist.count") { press("quick_list:birthday") }
    assert_nil @user.reload.bot_state
  end

  test "a typed name still works" do
    press("new_list")
    say("Мой день")

    assert_equal "Мой день", @user.wishlists.last.title
  end

  test "the first gift is saved right after its name and offers sending the list" do
    press("new_list")
    press("quick_list:wishes")
    list = @user.wishlists.last

    assert_difference("Item.count", 1) { say("Настольная игра") }
    item = list.items.last
    assert_equal "Настольная игра", item.title
    assert_nil @user.reload.bot_state

    assert_includes screen[:text], "первый подарок в списке «Хотелки»"
    share = buttons.first
    assert_equal Bot::Inline.share_query(list), share.switch_inline_query_chosen_chat.query
    assert_equal [ "add_item:#{list.id}", "edit_item_field:url:#{item.id}", "open_list:#{list.id}" ], callbacks.compact
  end

  test "a link sent first still asks for the name and keeps the link" do
    press("new_list")
    press("quick_list:wishes")
    say("https://ozon.ru/t/abc")
    assert_equal "adding_item_title", @user.reload.bot_state

    say("Плед")
    item = @user.items.last
    assert_equal "https://ozon.ru/t/abc", item.url
    assert_includes screen[:text], "первый подарок"
    refute_includes callbacks, "edit_item_field:url:#{item.id}"
  end

  test "after the first gift the regular link step comes back" do
    list = @user.wishlists.create!(title: "Хотелки")
    list.items.create!(title: "Книга")

    press("add_item:#{list.id}")
    say("Лампа")
    assert_equal "adding_item_url", @user.reload.bot_state
  end

  test "the menu offers to continue an empty list until the first gift" do
    list = @user.wishlists.create!(title: "Новый год")
    say("/start")

    assert_includes screen[:text], "«Новый год» пока пустой"
    assert_equal "first_gift:#{list.id}", callbacks.first
    assert_equal "primary", buttons.first.style
    refute_equal "primary", buttons.find { |button| button.callback_data == "new_list" }.style

    press("first_gift:#{list.id}")
    assert_equal({ "wishlist_id" => list.id, "first_item" => true }, @user.reload.bot_payload)
    say("Свеча")
    assert_includes screen[:text], "первый подарок"

    say("/start")
    refute_includes callbacks, "first_gift:#{list.id}"
  end

  test "a link waiting for its name survives /start and the menu button" do
    list = @user.wishlists.create!(title: "Хотелки")
    press("first_gift:#{list.id}")
    say("https://ozon.ru/t/abc")

    say("/start")
    assert_equal "adding_item_title", @user.reload.bot_state
    assert_includes screen[:text], I18n.t("bot.commands.input_active")
    assert_equal %w[resume_input cancel_input], callbacks.first(2)
    refute_includes callbacks, "first_gift:#{list.id}"

    press("main_menu")
    assert_equal "adding_item_title", @user.reload.bot_state

    press("resume_input")
    say("Плед")
    assert_equal "https://ozon.ru/t/abc", list.items.sole.url
  end

  test "other commands still end the newcomer's draft" do
    list = @user.wishlists.create!(title: "Хотелки")
    press("first_gift:#{list.id}")
    say("https://ozon.ru/t/abc")

    say("/my")
    assert_nil @user.reload.bot_state
  end

  test "someone else's list can't be continued" do
    other = User.create!(telegram_id: 99502, first_name: "Other").wishlists.create!(title: "Чужой")

    press("first_gift:#{other.id}")
    assert_nil @user.reload.bot_state
  end

  private

  def screen
    @screens.last
  end

  def buttons
    screen[:reply_markup].inline_keyboard.flatten
  end

  def callbacks
    buttons.map(&:callback_data)
  end

  def say(text)
    @message_id += 1
    Bot::Commands.handle(@bot, Telegram::Bot::Types::Message.new(
      message_id: @message_id, date: 1, text: text,
      chat: { id: @user.telegram_id, type: "private" },
      from: { id: @user.telegram_id, is_bot: false, first_name: @user.first_name }
    ))
  end

  def press(data)
    Bot::Callbacks.handle(@bot, Telegram::Bot::Types::CallbackQuery.new(
      id: "onboarding", chat_instance: "chat", data: data,
      from: { id: @user.telegram_id, is_bot: false, first_name: @user.first_name },
      message: { message_id: 7, date: 1, chat: { id: @user.telegram_id, type: "private" }, text: "Screen" }
    ))
  end
end
