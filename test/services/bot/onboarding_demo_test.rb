require "test_helper"
require "mocha/minitest"
require "telegram/bot"

Telegram::Bot::Types::Update

# "How it looks" shows a friend's list from fixed texts. Trying a
# reservation there saves nothing and notifies nobody.
class BotOnboardingDemoTest < ActiveJob::TestCase
  setup do
    @user = User.create!(telegram_id: 99601, first_name: "New")
    @api = mock("TelegramApi")
    @api.stubs(:answer_callback_query).with { |params| @answer = params; true }
    @bot = stub(api: @api)
    @screens = []
    @api.stubs(:send_message).with { |params| @screens << params; true }
    @api.stubs(:edit_message_text).with { |params| @screens << params; true }
    @message_id = 100
  end

  test "the welcome offers the demo next to creating a list" do
    say("/start")
    assert_equal %w[new_list demo], callbacks
  end

  test "the demo shows a friend's list with one gift already taken" do
    press("demo")

    assert_includes screen[:text], I18n.t("bot.demo.intro")
    assert_includes screen[:text], I18n.t("bot.demo.try")
    assert_equal %w[demo:0 demo_taken demo:2 demo:3 new_list main_menu], callbacks
    assert buttons[1].text.start_with?("✓ ")
  end

  test "trying a reservation saves nothing and explains what the owner sees" do
    assert_no_difference([ "Wishlist.count", "Item.count", "ListViewer.count" ]) do
      assert_no_enqueued_jobs do
        press("demo")
        press("demo:2")
      end
    end

    assert_includes screen[:text], I18n.t("bot.screens.item.owner_reserved")
    assert_includes screen[:text], I18n.t("bot.demo.gifts")[2]
    assert buttons[2].text.start_with?("★ ")
    assert_equal "demo", buttons[2].callback_data
    assert_equal "primary", buttons[2].style
    assert_nil @user.reload.first_list_at
  end

  test "the taken gift answers with a popup and an unknown index shows the plain demo" do
    press("demo_taken")
    assert_equal I18n.t("bot.demo.taken_notice"), @answer[:text]

    press("demo:1")
    assert_includes screen[:text], I18n.t("bot.demo.try")
    press("demo:9")
    assert_includes screen[:text], I18n.t("bot.demo.try")
  end

  test "the demo keeps an unfinished input and goes back to it" do
    list = @user.wishlists.create!(title: "Хотелки")
    press("first_gift:#{list.id}")
    say("https://ozon.ru/t/abc")

    press("demo")
    press("demo:0")
    assert_equal "adding_item_title", @user.reload.bot_state
    assert_equal "resume_input", callbacks.last

    press("resume_input")
    assert_equal "adding_item_title", @user.reload.bot_state
  end

  test "creating a list from the demo starts the regular flow" do
    press("demo")
    press("new_list")
    assert_equal "creating_list", @user.reload.bot_state
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
      id: "demo", chat_instance: "chat", data: data,
      from: { id: @user.telegram_id, is_bot: false, first_name: @user.first_name },
      message: { message_id: 7, date: 1, chat: { id: @user.telegram_id, type: "private" }, text: "Screen" }
    ))
  end
end
