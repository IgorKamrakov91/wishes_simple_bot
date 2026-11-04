require "test_helper"
require "mocha/minitest"
require "telegram/bot"

# Load the gem's types the way real updates do
Telegram::Bot::Types::Update

class BotOnboardingAndSharingTest < ActiveSupport::TestCase
  setup do
    @api = mock("TelegramApi")
    @api.stubs(:answer_callback_query)
    @bot = mock("TelegramBot")
    @bot.stubs(:api).returns(@api)
    @sent = []
    @api.stubs(:send_message).with { |params| @sent << params; true }
    @api.stubs(:edit_message_text).with { |params| @sent << params; true }

    @user = User.create!(telegram_id: 80001, first_name: "Анна")
    @owner = User.create!(telegram_id: 80002, first_name: "Игорь")
    @friends_list = @owner.wishlists.create!(title: "День рождения")
  end

  def start(user = @user)
    Bot::Commands.handle(@bot, Telegram::Bot::Types::Message.new(
      message_id: 1, date: 1, text: "/start",
      chat: { id: user.telegram_id, type: "private" },
      from: { id: user.telegram_id, is_bot: false, first_name: user.first_name }
    ))
  end

  def open_list(list, user: @user)
    Bot::Callbacks.handle(@bot, Telegram::Bot::Types::CallbackQuery.new(
      id: "1", chat_instance: "chat", data: "open_list:#{list.id}",
      from: { id: user.telegram_id, is_bot: false, first_name: user.first_name },
      message: { message_id: 7, date: 1, chat: { id: user.telegram_id, type: "private" }, text: "Menu" }
    ))
  end

  def buttons
    @sent.last[:reply_markup].inline_keyboard.flatten
  end

  def inline_query(text, user: @owner)
    results = nil
    @api.expects(:answer_inline_query).with { |params| results = params; true }
    Bot::Inline.handle_query(@bot, Telegram::Bot::Types::InlineQuery.new(
      id: "q", query: text, offset: "",
      from: { id: user.telegram_id, is_bot: false, first_name: user.first_name }
    ))
    results
  end

  test "a newcomer sees how it works and one button to start" do
    start

    assert_equal I18n.t("bot.screens.main.welcome", name: "Анна"), @sent.last[:text]
    assert_equal [ [ I18n.t("bot.buttons.create_first_list"), "new_list" ] ], buttons.map { |b| [ b.text, b.callback_data ] }
  end

  test "a guest without lists sees friends' lists and a hint, no zero counters" do
    @friends_list.admit!(@user)
    start

    text = @sent.last[:text]
    assert_includes text, I18n.t("bot.screens.main.shared", shared: 1)
    assert_includes text, I18n.t("bot.screens.main.own_hint")
    refute_includes text, "Твоих списков"
  end

  test "an owner sees their counters" do
    list = @user.wishlists.create!(title: "Новый год")
    list.items.create!(title: "Книга")
    start

    assert_includes @sent.last[:text], I18n.t("bot.screens.main.own", lists: 1, items: 1)
    refute_includes @sent.last[:text], I18n.t("bot.screens.main.own_hint")
  end

  test "a guest without lists can create one from a friend's list" do
    @friends_list.admit!(@user)
    open_list(@friends_list)

    assert_includes buttons.map(&:callback_data), "new_list"
  end

  test "a guest who already has lists doesn't get the extra button" do
    @user.wishlists.create!(title: "Мой")
    @friends_list.admit!(@user)
    open_list(@friends_list)

    refute_includes buttons.map(&:callback_data), "new_list"
  end

  test "the owner can send the list to a friend through the chat picker" do
    open_list(@friends_list, user: @owner)

    send_button = buttons.find { |b| b.text == I18n.t("bot.buttons.send_to_friend") }
    picker = send_button.switch_inline_query_chosen_chat
    assert_equal "share_#{@friends_list.id}", picker.query
    assert picker.allow_user_chats
    assert picker.allow_group_chats
    assert buttons.any?(&:copy_text), "copying the link stays as a fallback"
  end

  test "the share query answers with a public card and the share link" do
    @friends_list.items.create!(title: "Книга")
    @friends_list.items.create!(title: "Плед")
    results = inline_query("share_#{@friends_list.id}")

    card = results[:results].sole
    assert_equal "2 подарка", card.description
    assert_equal I18n.t("bot.inline.card", owner: "Игорь", title: "День рождения", gifts: "2 подарка"),
                 card.input_message_content.message_text
    assert_equal "https://t.me/#{(ENV['BOT_USERNAME'].presence || 'PodarkiNeOtdarkiBot').delete_prefix('@')}?start=l_#{@friends_list.share_token}",
                 card.reply_markup.inline_keyboard.flatten.sole.url
    assert results[:is_personal]
  end

  test "nobody can share someone else's list by its id" do
    results = inline_query("share_#{@friends_list.id}", user: @user)

    assert_empty results[:results]
  end

  test "search ignores case and treats % literally" do
    @owner.wishlists.create!(title: "Скидки 100%")
    assert_equal [ "День рождения" ], inline_query("день").fetch(:results).map(&:title)
    assert_equal [ "Скидки 100%" ], inline_query("100%").fetch(:results).map(&:title)
    assert_empty inline_query("%%").fetch(:results)
  end

  test "Russian plural forms" do
    assert_equal [ "1 подарок", "3 подарка", "5 подарков", "11 подарков", "21 подарок", "0 подарков" ],
                 [ 1, 3, 5, 11, 21, 0 ].map { |n| I18n.t("bot.inline.gifts", count: n, locale: :ru) }
  end
end
