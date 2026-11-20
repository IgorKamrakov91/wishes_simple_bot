require "test_helper"
require "mocha/minitest"
require "telegram/bot"

Telegram::Bot::Types::Update

class BotOnboardingFunnelTest < ActiveSupport::TestCase
  setup do
    @api = stub
    @api.stubs(:send_message)
    @api.stubs(:edit_message_text)
    @api.stubs(:answer_callback_query)
    @api.stubs(:answer_inline_query)
    @bot = stub(api: @api)
    @telegram_id = 97803
    @update_id = 9780300
  end

  test "tagged addressed starts enter the normal welcome and do not overwrite attribution on replay" do
    update = message_update("/start@#{Bot::Commands.bot_username} src_winter-2026")
    @api.expects(:send_message).at_least_once.with { |params| params[:text].include?(I18n.t("bot.screens.main.welcome", name: "Guest")) }
    Bot::Dispatcher.dispatch(@bot, update)
    user = User.find_by!(telegram_id: @telegram_id)
    assert_equal "campaign_start", user.first_contact_kind
    assert_equal "winter-2026", user.acquisition_source
    assert user.first_private_start_at
    before = user.attributes.slice(*OnboardingFunnel::FIELDS)
    travel 1.hour do
      Bot::Dispatcher.dispatch(@bot, update)
      Bot::Dispatcher.dispatch(@bot, message_update("/start src_another"))
    end
    assert_equal before, user.reload.attributes.slice(*OnboardingFunnel::FIELDS)
  end

  test "a source argument during input is never saved as a list or gift" do
    Bot::Dispatcher.dispatch(@bot, message_update("/start"))
    user = User.find_by!(telegram_id: @telegram_id)
    user.start_creating_list!
    assert_no_difference([ "Wishlist.count", "Item.count" ]) do
      Bot::Dispatcher.dispatch(@bot, message_update("/start src_winter"))
    end
    assert_equal "winter", user.reload.acquisition_source
    assert_equal "start", user.first_contact_kind
  end

  test "malformed campaign arguments keep existing input and cannot become attribution" do
    Bot::Dispatcher.dispatch(@bot, message_update("/start"))
    user = User.find_by!(telegram_id: @telegram_id)
    user.start_creating_list!
    [ "/start src_", "/start src_a extra", "/start src_#{'a' * 61}", "/start src_a&token=secret" ].each do |text|
      assert_no_difference("Wishlist.count") { Bot::Dispatcher.dispatch(@bot, message_update(text)) }
      assert_equal "creating_list", user.reload.bot_state
      assert_nil user.acquisition_source
    end
  end

  test "group campaign prompts preserve the payload but tracking starts only in private" do
    @api.expects(:send_message).with do |params|
      button = params[:reply_markup].inline_keyboard.flatten.sole
      button.url == "#{Bot::Commands.bot_link}?start=src_winter"
    end
    Bot::Dispatcher.dispatch(@bot, message_update("/start src_winter", chat_type: "group"))
    refute User.exists?(telegram_id: @telegram_id)

    Bot::Dispatcher.dispatch(@bot, message_update("/start src_winter"))
    assert_equal "winter", User.find_by!(telegram_id: @telegram_id).acquisition_source
  end

  test "inline and callback first contacts are recorded without inventing a private start" do
    inline("anything")
    user = User.find_by!(telegram_id: @telegram_id)
    assert_equal "inline_query", user.first_contact_kind
    assert_nil user.first_private_start_at
    @telegram_id += 1
    Bot::Dispatcher.dispatch(@bot, callback_update("main_menu"))
    user = User.find_by!(telegram_id: @telegram_id)
    assert_equal "callback", user.first_contact_kind
    assert_nil user.first_private_start_at
    @telegram_id += 1
    Bot::Dispatcher.dispatch(@bot, message_update("hello"))
    assert_equal "message", User.find_by!(telegram_id: @telegram_id).first_contact_kind
  end

  test "only owned explicit inline share queries record a card request" do
    inline("anything")
    user = User.find_by!(telegram_id: @telegram_id)
    own = user.wishlists.create!(title: "Mine")
    other = User.create!(telegram_id: 97809).wishlists.create!(title: "Other")
    inline("share_#{other.id}")
    assert_nil user.reload.first_share_query_at
    inline("share_#{own.id}")
    first = user.reload.first_share_query_at
    assert first
    travel 1.hour do
      inline("share_#{own.id}")
      assert_equal first, user.reload.first_share_query_at
    end
    assert_nil user.first_shared_list_open_at
  end

  test "valid guest invitation openings are distinct from owner opens or invalid tokens" do
    owner = User.create!(telegram_id: 97809)
    list = owner.wishlists.create!(title: "Birthday")
    Bot::Dispatcher.dispatch(@bot, message_update("/start l_invalid"))
    user = User.find_by!(telegram_id: @telegram_id)
    assert_nil user.first_shared_list_open_at
    Bot::Dispatcher.dispatch(@bot, message_update("/start l_#{list.share_token}"))
    assert list.has_viewer?(user)
    first = user.reload.first_shared_list_open_at
    assert first
    assert_nil user.acquisition_source
    travel 1.hour do
      Bot::Dispatcher.dispatch(@bot, message_update("/start list_#{list.id}"))
      assert_equal first, user.reload.first_shared_list_open_at
    end
    @telegram_id = owner.telegram_id
    Bot::Dispatcher.dispatch(@bot, message_update("/start l_#{list.share_token}"))
    assert_nil owner.reload.first_shared_list_open_at
  end

  test "manual saving and a repeated webhook record just one first gift" do
    Bot::Dispatcher.dispatch(@bot, message_update("/start"))
    user = User.find_by!(telegram_id: @telegram_id)
    list = user.wishlists.create!(title: "Birthday")
    user.start_adding_item!(wishlist_id: list.id)
    # A newcomer's first gift is saved right after its name
    update = message_update("Book")
    assert_difference("Item.count", 1) do
      2.times { Bot::Dispatcher.dispatch(@bot, update) }
    end
    assert_equal list.items.sole.created_at, user.reload.first_item_at
    refute user.onboarding?
  end

  private

  def message_update(text, chat_type: "private")
    @update_id += 1
    Telegram::Bot::Types::Update.new(update_id: @update_id, message: {
      message_id: @update_id, date: 1, text: text,
      chat: { id: @telegram_id, type: chat_type },
      from: { id: @telegram_id, is_bot: false, first_name: "Guest" }
    })
  end

  def callback_update(data)
    @update_id += 1
    Telegram::Bot::Types::Update.new(update_id: @update_id, callback_query: {
      id: @update_id.to_s, chat_instance: "chat", data: data,
      from: { id: @telegram_id, is_bot: false, first_name: "Guest" },
      message: { message_id: 1, date: 1, chat: { id: @telegram_id, type: "private" }, text: "Menu" }
    })
  end

  def inline(query)
    Bot::Dispatcher.dispatch(@bot, Telegram::Bot::Types::Update.new(update_id: (@update_id += 1), inline_query: {
      id: "query", query: query, offset: "",
      from: { id: @telegram_id, is_bot: false, first_name: "Guest" }
    }))
  end
end
