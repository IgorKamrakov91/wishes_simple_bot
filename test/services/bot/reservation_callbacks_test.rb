require "test_helper"
require "mocha/minitest"
require "telegram/bot"

Telegram::Bot::Types::Update

class BotReservationCallbacksTest < ActiveSupport::TestCase
  setup do
    # Reservation logic only; notifications have their own tests
    @owner = User.create!(telegram_id: 41001, first_name: "Owner", notify_own_reservations: false)
    @guest = User.create!(telegram_id: 41002, first_name: "Guest")
    @other = User.create!(telegram_id: 41003, first_name: "Other")
    @wishlist = @owner.wishlists.create!(title: "Birthday")
    @wishlist.list_viewers.create!(user: @guest)
    @wishlist.list_viewers.create!(user: @other)
    @item = @wishlist.items.create!(title: "Puzzle")
    @screens = []
    @notices = []
    @api = mock("TelegramApi")
    @api.stubs(:edit_message_text).with { |params| @screens << params; true }
    @api.stubs(:answer_callback_query).with { |params| @notices << params[:text]; true }
    @bot = mock("TelegramBot")
    @bot.stubs(:api).returns(@api)
    Telegram::Bot::Client.expects(:new).never
    NotificationJob.expects(:perform_later).never
  end

  test "replayed reserve keeps the booking without notifying viewers" do
    2.times { press("reserve_item:#{@item.id}:0") }

    assert_equal @guest.telegram_id, @item.reload.reserved_by
    assert_equal 1, @item.reservation_version
    assert_equal [ I18n.t("bot.messages.reserved_notice") ] * 2, @notices
    assert_includes @screens.last[:text], I18n.t("bot.screens.item.guest_mine")
    assert_includes current_callbacks, "unreserve_item:#{@item.id}:1"
  end

  test "another guest cannot take or release a booked gift" do
    @item.reserve_for!(@other)
    press("reserve_item:#{@item.id}:0")
    press("unreserve_item:#{@item.id}:1")

    assert_equal @other.telegram_id, @item.reload.reserved_by
    assert_equal 1, @item.reservation_version
    assert_equal [ I18n.t("bot.messages.already_reserved") ] * 2, @notices
    assert current_callbacks.none? { |data| data.start_with?("reserve_item:", "unreserve_item:") }
  end

  test "replayed release leaves the gift free without notifying viewers" do
    @item.reserve_for!(@guest)
    2.times { press("unreserve_item:#{@item.id}:1") }

    assert_nil @item.reload.reserved_by
    assert_equal 2, @item.reservation_version
    assert_equal [ I18n.t("bot.messages.unreserved_notice") ] * 2, @notices
    assert_includes current_callbacks, "reserve_item:#{@item.id}:2"
  end

  test "delayed requests cannot recreate or cancel a newer booking" do
    press("reserve_item:#{@item.id}:0")
    press("unreserve_item:#{@item.id}:1")
    press("reserve_item:#{@item.id}:0")
    assert_nil @item.reload.reserved_by
    assert_equal I18n.t("bot.messages.reservation_changed"), @notices.last

    press("reserve_item:#{@item.id}:2")
    press("unreserve_item:#{@item.id}:1")
    assert_equal @guest.telegram_id, @item.reload.reserved_by
    assert_equal 3, @item.reservation_version
    assert_equal I18n.t("bot.messages.reservation_changed"), @notices.last
    assert_includes current_callbacks, "unreserve_item:#{@item.id}:3"
  end

  test "an owner cannot reserve or release their own gift" do
    press("reserve_item:#{@item.id}:0", user: @owner)
    assert_nil @item.reload.reserved_by

    @item.reserve_for!(@guest)
    press("unreserve_item:#{@item.id}:1", user: @owner)
    assert_equal @guest.telegram_id, @item.reload.reserved_by
    assert_equal [ I18n.t("bot.messages.cannot_reserve_own") ] * 2, @notices
  end

  test "legacy toggle buttons only refresh free and reserved gifts" do
    press("toggle_reserve:#{@item.id}")
    assert_nil @item.reload.reserved_by
    assert_equal 0, @item.reservation_version
    assert_includes current_callbacks, "reserve_item:#{@item.id}:0"

    @item.reserve_for!(@guest)
    press("toggle_reserve:#{@item.id}")
    assert_equal @guest.telegram_id, @item.reload.reserved_by
    assert_equal 1, @item.reservation_version
    assert_includes current_callbacks, "unreserve_item:#{@item.id}:1"
  end

  test "a guessed reserve callback cannot book a gift or grant list access" do
    stranger = User.create!(telegram_id: 41004, first_name: "Stranger")
    @api.expects(:send_message).never
    @api.expects(:answer_callback_query).with(
      callback_query_id: "reservation-callback", text: I18n.t("bot.messages.not_available"), show_alert: true
    )

    press("reserve_item:#{@item.id}:0", user: stranger)

    assert_nil @item.reload.reserved_by
    assert_equal 0, @item.reservation_version
    assert_not @wishlist.has_viewer?(stranger)
    assert_empty @screens
  end

  private

  def current_callbacks
    @screens.last[:reply_markup].inline_keyboard.flatten.filter_map(&:callback_data)
  end

  def press(data, user: @guest)
    callback = Telegram::Bot::Types::CallbackQuery.new(
      id: "reservation-callback", chat_instance: "chat", data: data,
      from: { id: user.telegram_id, is_bot: false, first_name: user.first_name },
      message: { message_id: 7, date: 1, chat: { id: user.telegram_id, type: "private" }, text: "Gift" }
    )
    Bot::Callbacks.handle(@bot, callback)
  end
end
