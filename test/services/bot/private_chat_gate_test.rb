require "test_helper"
require "mocha/minitest"
require "telegram/bot"

Telegram::Bot::Types::Update

class BotPrivateChatGateTest < ActiveSupport::TestCase
  setup do
    @previous_username = ENV["BOT_USERNAME"]
    ENV["BOT_USERNAME"] = "WishBot"
    @owner = User.create!(telegram_id: 71001, first_name: "Owner")
    @guest = User.create!(telegram_id: 71002, first_name: "Guest")
    @wishlist = @owner.wishlists.create!(title: "Private birthday")
    @wishlist.admit!(@guest)
    @item = @wishlist.items.create!(title: "Private gift")
    @api = mock("TelegramApi")
    @bot = mock("TelegramBot")
    @bot.stubs(:api).returns(@api)
  end

  teardown do
    ENV["BOT_USERNAME"] = @previous_username
  end

  test "group commands show only a generic private chat link without loading the user" do
    User.expects(:find_or_create_from_telegram).never
    @api.expects(:send_message).with { |params| private_prompt?(params) }.times(3)

    dispatch_message("/my")
    dispatch_message("/new@wishbot", type: "supergroup")
    dispatch_message("/start", user: @guest)

    assert_equal 1, @wishlist.list_viewers.count
    assert_equal 1, @wishlist.items.count
  end

  test "a group invitation carries its token without reading data or touching private input" do
    @owner.start_creating_list!
    before = @owner.attributes
    User.expects(:find_or_create_from_telegram).never
    Wishlist.expects(:find_by).never
    Wishlist.expects(:accessible_to).never
    Wishlist.any_instance.expects(:admit!).never
    @api.expects(:send_message).with { |params| private_prompt?(params, payload: "l_#{@wishlist.share_token}") }.twice

    dispatch_message("/start l_#{@wishlist.share_token}")
    dispatch_message("/start@wishbot\tl_#{@wishlist.share_token}", type: "supergroup")

    assert_equal before, @owner.reload.attributes
    assert_equal 1, @wishlist.list_viewers.count
    assert_equal 1, @wishlist.items.count
  end

  test "legacy group invitations retain their payload for the private access check" do
    User.expects(:find_or_create_from_telegram).never
    Wishlist.expects(:accessible_to).never
    @api.expects(:send_message).with { |params| private_prompt?(params, payload: "list_#{@wishlist.id}") }

    dispatch_message("/start list_#{@wishlist.id}", user: @guest)

    assert_equal 1, @wishlist.list_viewers.count
  end

  test "unsupported or malformed group payloads only open the bot" do
    User.expects(:find_or_create_from_telegram).never
    inputs = [ "/start l_", "/start list_nope", "/start unknown", "/start https://example.com", "/start l_abc&other=value",
               "/start l_abc extra", "/start l_#{'a' * 63}", "/help l_abc", "/new@WishBot l_abc" ]
    @api.expects(:send_message).with { |params| private_prompt?(params) }.times(inputs.size)

    inputs.each { |input| dispatch_message(input) }

    assert_equal 1, @wishlist.list_viewers.count
  end

  test "group invitations addressed to another bot are ignored" do
    User.expects(:find_or_create_from_telegram).never
    @api.expects(:send_message).never

    dispatch_message("/start@AnotherBot l_#{@wishlist.share_token}")

    assert_equal 1, @wishlist.list_viewers.count
  end

  test "only the private continuation admits the guest and shows the invited list" do
    payload = "l_#{@wishlist.share_token}"
    ListViewer.where(wishlist: @wishlist, user: @guest).delete_all
    @api.expects(:send_message).with { |params| private_prompt?(params, payload: payload) }
    dispatch_message("/start@WishBot #{payload}", user: @guest)
    refute @wishlist.has_viewer?(@guest)

    @api.expects(:send_message).with do |params|
      params[:chat_id] == @guest.telegram_id && params[:text].include?(@wishlist.title)
    end
    dispatch_message("/start #{payload}", user: @guest, type: "private")

    assert @wishlist.has_viewer?(@guest)
  end

  test "group conversation and commands for another bot leave private input untouched" do
    @owner.start_creating_list!
    before = @owner.attributes
    User.expects(:find_or_create_from_telegram).never
    @api.expects(:send_message).never

    dispatch_message("New personal list")
    dispatch_message("/my@AnotherBot")
    dispatch_message("/ban")
    dispatch_message(nil)

    assert_equal before, @owner.reload.attributes
    assert_equal [ @wishlist.id ], @owner.wishlists.pluck(:id)
  end

  test "group buttons cannot create delete save or cancel a private draft" do
    @owner.update!(bot_state: "adding_item_url",
                   bot_payload: { "wishlist_id" => @wishlist.id, "title" => "Draft gift", "draft_id" => "draft1" })
    before = @owner.attributes
    User.expects(:find_or_create_from_telegram).never
    @api.expects(:edit_message_text).never
    actions = [ "show_lists", "new_list", "delete_item:#{@item.id}", "skip_item_url:draft1" ]
    @api.expects(:send_message).with { |params| private_prompt?(params) }.times(actions.size)
    @api.expects(:answer_callback_query).with(has_entries(show_alert: true, text: I18n.t("bot.messages.private_chat_only"))).times(actions.size)

    assert_no_difference("Item.count") do
      actions.each { |data| dispatch_callback(data) }
    end
    assert_equal before, @owner.reload.attributes
    assert_equal "Private gift", @item.reload.title
  end

  test "group buttons cannot book or release gifts" do
    User.expects(:find_or_create_from_telegram).never
    @api.expects(:edit_message_text).never
    @api.expects(:send_message).with { |params| private_prompt?(params) }.twice
    @api.expects(:answer_callback_query).twice

    dispatch_callback("reserve_item:#{@item.id}:0", user: @guest, type: "supergroup")
    assert_nil @item.reload.reserved_by

    @item.reserve_for!(@guest)
    dispatch_callback("unreserve_item:#{@item.id}:1", user: @guest)
    assert_equal @guest.telegram_id, @item.reload.reserved_by
    assert_equal 1, @item.reservation_version
  end

  test "an inaccessible group message is also blocked before dispatch" do
    User.expects(:find_or_create_from_telegram).never
    @api.expects(:send_message).with { |params| private_prompt?(params) }
    @api.expects(:answer_callback_query)

    dispatch_callback("delete_item:#{@item.id}", date: 0)

    assert Item.exists?(@item.id)
  end

  test "expired or failed group callback acknowledgements cannot retry an action" do
    User.expects(:find_or_create_from_telegram).never
    @api.expects(:send_message).with { |params| private_prompt?(params) }
    @api.expects(:answer_callback_query).once.raises(Faraday::TimeoutError)

    assert_nothing_raised { dispatch_callback("delete_item:#{@item.id}") }
    assert Item.exists?(@item.id)
  end

  test "a failed group prompt still prevents dispatch and acknowledges the callback" do
    User.expects(:find_or_create_from_telegram).never
    @api.expects(:send_message).once.raises(Faraday::ConnectionFailed)
    @api.expects(:answer_callback_query).once

    assert_nothing_raised { dispatch_callback("delete_item:#{@item.id}") }
    assert Item.exists?(@item.id)
  end

  test "private messages still open personal screens" do
    @api.expects(:send_message).with do |params|
      params[:chat_id] == @owner.telegram_id && params[:reply_markup].inline_keyboard.flatten.any? { |button|
        button.callback_data == "open_list:#{@wishlist.id}"
      }
    end

    dispatch_message("/my", type: "private")
  end

  test "private buttons still open personal screens" do
    @api.expects(:edit_message_text).with do |params|
      params[:chat_id] == @owner.telegram_id && params[:text].include?(@wishlist.title)
    end
    @api.expects(:answer_callback_query)

    dispatch_callback("open_list:#{@wishlist.id}", type: "private")
  end

  test "inline share queries still work" do
    update = Telegram::Bot::Types::Update.new(update_id: 1,
      inline_query: { id: "inline-query", from: telegram_user(@owner), query: "", offset: "" })
    Bot::Inline.expects(:handle_query).with(@bot, update.inline_query)

    Bot::Dispatcher.dispatch(@bot, update)
  end

  test "legacy inline invitations still apply their access check" do
    @owner.start_creating_list!
    @api.expects(:answer_callback_query).with(callback_query_id: "callback", url: "https://t.me/WishBot?start=l_#{@wishlist.share_token}")

    dispatch_callback("open_shared_list:#{@wishlist.id}", inline: true)

    assert_equal "creating_list", @owner.reload.bot_state
  end

  test "arbitrary inline callbacks cannot invoke personal actions" do
    @owner.start_creating_list!
    before = @owner.attributes
    User.expects(:find_or_create_from_telegram).never
    @api.expects(:send_message).never
    @api.expects(:edit_message_text).never
    @api.expects(:answer_callback_query).with(has_entries(show_alert: true, text: I18n.t("bot.messages.private_chat_only")))

    dispatch_callback("delete_item:#{@item.id}", inline: true)

    assert Item.exists?(@item.id)
    assert_equal before, @owner.reload.attributes
  end

  private

  def telegram_user(user)
    { id: user.telegram_id, is_bot: false, first_name: user.first_name }
  end

  def private_prompt?(params, payload: nil)
    return false unless params[:chat_id] == -71001 && params[:text] == I18n.t("bot.messages.private_chat_only")

    buttons = params[:reply_markup].inline_keyboard.flatten
    url = payload ? "https://t.me/WishBot?start=#{payload}" : "https://t.me/WishBot"
    buttons.one? && buttons.first.url == url && buttons.first.callback_data.nil?
  end

  def dispatch_message(text, user: @owner, type: "group")
    message = { message_id: 1, date: 1, from: telegram_user(user),
                chat: { id: type == "private" ? user.telegram_id : -71001, type: type } }
    message[:text] = text if text
    @update_id = (@update_id || 0) + 1
    Bot::Dispatcher.dispatch(@bot, Telegram::Bot::Types::Update.new(update_id: @update_id, message: message))
  end

  def dispatch_callback(data, user: @owner, type: "group", inline: false, date: 1)
    callback = { id: "callback", chat_instance: "chat", data: data, from: telegram_user(user) }
    if inline
      callback[:inline_message_id] = "inline-message"
    else
      callback[:message] = { message_id: 1, date: date,
                             chat: { id: type == "private" ? user.telegram_id : -71001, type: type }, text: "Old screen" }
    end
    @update_id = (@update_id || 0) + 1
    Bot::Dispatcher.dispatch(@bot, Telegram::Bot::Types::Update.new(update_id: @update_id, callback_query: callback))
  end
end
