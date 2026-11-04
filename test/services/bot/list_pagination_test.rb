require "test_helper"
require "mocha/minitest"
require "telegram/bot"

class BotListPaginationTest < ActiveSupport::TestCase
  setup do
    @user = User.create!(telegram_id: 92001, first_name: "Guest")
    @owner = User.create!(telegram_id: 92002, first_name: "Owner")
    @api = mock("TelegramApi")
    @api.stubs(:answer_callback_query)
    @bot = mock("TelegramBot")
    @bot.stubs(:api).returns(@api)
    @rendered = []
    @api.stubs(:edit_message_text).with { |params| @rendered << params; true }
  end

  def callback(data)
    Bot::Callbacks.handle(@bot, Telegram::Bot::Types::CallbackQuery.new(
      id: "page", chat_instance: "chat", data: data,
      from: { id: @user.telegram_id, is_bot: false, first_name: @user.first_name },
      message: { message_id: 1, date: 1, chat: { id: @user.telegram_id, type: "private" }, text: "Menu" }
    ))
  end

  def buttons
    @rendered.last.fetch(:reply_markup).inline_keyboard.flatten
  end

  def list_ids
    buttons.filter_map { |button| button.callback_data[/\Aopen_list:(\d+)\z/, 1]&.to_i }
  end

  def create_lists(user, count)
    count.times.map { |index| user.wishlists.create!(title: "Wishlist #{index}") }
  end

  test "old callbacks open page one and page callbacks cover only the current user's lists" do
    lists = create_lists(@user, 12)
    create_lists(@owner, 2)

    callback("show_lists")
    assert_equal lists.first(5).map(&:id), list_ids
    assert_includes buttons.map(&:callback_data), "show_lists:1"
    refute_includes buttons.map(&:callback_data), "show_lists:-1"
    refute_includes @rendered.last[:text], lists.first.title

    callback("show_lists:1")
    assert_equal lists[5, 5].map(&:id), list_ids
    assert_includes buttons.map(&:callback_data), "show_lists:0"
    assert_includes buttons.map(&:callback_data), "show_lists:2"
    assert_includes @rendered.last[:text], "Страница 2 из 3"

    callback("show_lists:2")
    assert_equal lists.last(2).map(&:id), list_ids
    refute_includes buttons.map(&:callback_data), "show_lists:3"
    assert buttons.none? { |button| button.callback_data == "noop" }
  end

  test "friends pages show only admitted lists with the owner and gift count" do
    lists = create_lists(@owner, 8)
    lists.first(7).each { |list| list.admit!(@user) }
    lists[5].items.create!(title: "Gift")

    callback("show_shared_lists")
    assert_equal lists.first(5).map(&:id), list_ids
    assert_includes buttons.map(&:callback_data), "show_shared_lists:1"

    callback("show_shared_lists:1")
    assert_equal lists[5, 2].map(&:id), list_ids
    assert_equal "Owner · Wishlist 5 · 1 подарок", buttons.first.text
    assert_includes buttons.map(&:callback_data), "show_shared_lists:0"
    refute_includes buttons.map(&:callback_data), "new_list"
    refute_includes @rendered.last[:text], "Owner"
  end

  test "stale pages clamp after deletion or revoked access" do
    lists = create_lists(@user, 6)
    lists.last.destroy!
    callback("show_lists:999999999999999999")
    assert_equal lists.first(5).map(&:id), list_ids
    assert_includes @rendered.last[:text], "Страница 1 из 1"

    shared = create_lists(@owner, 6)
    shared.each { |list| list.admit!(@user) }
    shared.last.list_viewers.delete_all
    callback("show_shared_lists:1")
    assert_equal shared.first(5).map(&:id), list_ids
  end

  test "empty collections keep working navigation without page buttons" do
    callback("show_lists:5")
    assert_includes @rendered.last[:text], I18n.t("bot.screens.my_lists.empty")
    assert_equal %w[new_list main_menu], buttons.map(&:callback_data)

    callback("show_shared_lists:5")
    assert_includes @rendered.last[:text], I18n.t("bot.screens.shared_lists.empty")
    assert_equal [ "main_menu" ], buttons.map(&:callback_data)
  end

  test "return from a list goes to its current collection page" do
    lists = create_lists(@user, 7)
    callback("open_list:#{lists.last.id}")
    assert_equal "show_lists:1", buttons.last.callback_data
    callback(buttons.last.callback_data)
    assert_equal lists.last(2).map(&:id), list_ids

    lists = create_lists(@owner, 7)
    lists.each { |list| list.admit!(@user) }
    callback("open_list:#{lists.last.id}")
    assert_equal "show_shared_lists:1", buttons.last.callback_data
    callback(buttons.last.callback_data)
    assert_equal lists.last(2).map(&:id), list_ids
  end

  test "long legacy names never grow collection text and are bounded in buttons" do
    @owner.update_columns(first_name: "<&" * 3000)
    lists = create_lists(@owner, 15)
    lists.each do |list|
      list.update_columns(title: "<&" * 3000)
      list.admit!(@user)
    end

    callback("show_shared_lists:1")
    assert_operator @rendered.last[:text].length, :<, 4096
    assert_equal 5, list_ids.size
    assert buttons.all? { |button| button.text.length < 100 }
    assert buttons.all? { |button| button.callback_data.bytesize <= 64 }
    assert_equal 1, @rendered.size
  end

  test "counting gifts does not instantiate items or off-page lists" do
    lists = create_lists(@user, 12)
    lists.first.items.create!(title: "Gift")
    records = Hash.new(0)
    listener = lambda { |*args|
      payload = args.last
      records[payload[:class_name]] += payload[:record_count]
    }
    ActiveSupport::Notifications.subscribed(listener, "instantiation.active_record") { callback("show_lists:1") }

    assert_equal 5, records["Wishlist"]
    assert_equal 0, records["Item"]
  end
end
