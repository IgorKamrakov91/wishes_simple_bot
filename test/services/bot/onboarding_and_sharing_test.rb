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

  def inline_query(text, user: @owner, offset: "")
    results = nil
    @api.expects(:answer_inline_query).with { |params| results = params; true }
    Bot::Inline.handle_query(@bot, Telegram::Bot::Types::InlineQuery.new(
      id: "q", query: text, offset: offset,
      from: { id: user.telegram_id, is_bot: false, first_name: user.first_name }
    ))
    results
  end

  test "a newcomer sees how it works, one button to start and the demo" do
    start

    assert_equal I18n.t("bot.screens.main.welcome", name: "Анна"), screen_text(@sent.last[:text])
    assert_equal [ [ I18n.t("bot.buttons.create_first_list"), "new_list" ], [ I18n.t("bot.demo.button"), "demo" ] ],
                 buttons.map { |b| [ b.text, b.callback_data ] }
    assert_equal [ "primary", nil ], buttons.map(&:style)
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

  test "inline browsing counts gifts without loading gift records" do
    empty_list = @owner.wishlists.create!(title: "Пустой")
    3.times { |i| @friends_list.items.create!(title: "Gift #{i}", description: "x" * 1000) }
    @user.wishlists.create!(title: "Private").items.create!(title: "Not shared")
    loaded_items = 0
    subscriber = ->(*args) do
      payload = args.last
      loaded_items += payload[:record_count] if payload[:class_name] == "Item"
    end

    result = ActiveSupport::Notifications.subscribed(subscriber, "instantiation.active_record") do
      inline_query("")
    end
    cards = result[:results].index_by(&:id)

    assert_equal I18n.t("bot.inline.gifts", count: 3), cards.fetch(@friends_list.id.to_s).description
    assert_equal I18n.t("bot.inline.gifts", count: 0), cards.fetch(empty_list.id.to_s).description
    assert_equal 2, cards.size
    assert_equal 0, loaded_items, "inline sharing needs counts, not full gift records"
  end

  test "legacy long titles stay shareable without changing the stored list" do
    title = "🎁" * 5000
    @friends_list.update_column(:title, title)

    [ :ru, :en ].each do |locale|
      I18n.with_locale(locale) do
        card = inline_query("share_#{@friends_list.id}")[:results].sole

        assert_equal title.truncate(Wishlist::TITLE_LIMIT), card.title
        assert_includes card.input_message_content.message_text, card.title
        assert_operator card.input_message_content.message_text.encode("UTF-16LE").bytesize / 2, :<=, 4096
        assert_equal Bot::Inline.share_link(@friends_list), card.reply_markup.inline_keyboard.flatten.sole.url
      end
    end

    assert_equal title, @friends_list.reload.title
  end

  test "inline cards bound unusually long owner names and keep the full name fallback" do
    @owner.update!(first_name: "", last_name: "Я" * 5000)
    card = Bot::Inline.inline_result_for_list(@friends_list)

    assert_includes card.input_message_content.message_text, @owner.full_name.truncate(100)
    assert_operator card.input_message_content.message_text.length, :<=, 4096
    assert_equal "Я" * 5000, @owner.reload.last_name
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

  test "inline browsing and search paginate all owned lists with a stable order" do
    40.times { |i| @owner.wishlists.create!(title: "День #{i}") }
    # Tied timestamps must not move results between pages.
    @owner.wishlists.update_all(updated_at: Time.current.change(usec: 0))
    foreign_list = @user.wishlists.create!(title: "День чужой")
    foreign_list.admit!(@owner)
    expected_ids = @owner.wishlists.order(id: :desc).pluck(:id).map(&:to_s)

    [ "", "день" ].each do |query|
      first = inline_query(query)
      second = inline_query(query, offset: first[:next_offset])
      last = inline_query(query, offset: second[:next_offset])

      assert_equal [ 20, 20, 1 ], [ first, second, last ].map { |page| page[:results].size }
      assert_equal [ "20", "40", "" ], [ first, second, last ].map { |page| page[:next_offset] }
      assert_equal expected_ids, [ first, second, last ].flat_map { |page| page[:results].map(&:id) }
      assert first[:is_personal]
      assert_equal 0, first[:cache_time]
    end
  end

  test "inline pagination ends on an exactly full page and beyond the last page" do
    19.times { |i| @owner.wishlists.create!(title: "List #{i}") }

    assert_equal "", inline_query("")[:next_offset]
    beyond = inline_query("", offset: "20")
    assert_empty beyond[:results]
    assert_equal "", beyond[:next_offset]
  end

  test "malformed inline offsets safely restart at the first page" do
    [ "-1", "abc", "1.5", "9" * 100 ].each do |offset|
      result = inline_query("", offset: offset)
      assert_equal [ @friends_list.id.to_s ], result[:results].map(&:id)
      assert_equal "", result[:next_offset]
    end
  end

  test "direct sharing returns only the requested list and no next page" do
    result = inline_query("share_#{@friends_list.id}")

    assert_equal [ @friends_list.id.to_s ], result[:results].map(&:id)
    assert_equal "", result[:next_offset]
    assert_empty inline_query("share_#{@friends_list.id}", offset: "20")[:results]
    assert_empty inline_query("share_#{@friends_list.id}", user: @user, offset: "20")[:results]
  end

  test "Russian plural forms" do
    assert_equal [ "1 подарок", "3 подарка", "5 подарков", "11 подарков", "21 подарок", "0 подарков" ],
                 [ 1, 3, 5, 11, 21, 0 ].map { |n| I18n.t("bot.inline.gifts", count: n, locale: :ru) }
  end
end
