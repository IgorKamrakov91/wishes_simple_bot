require "test_helper"
require "mocha/minitest"
require "telegram/bot"

class BotMyReservationsTest < ActiveJob::TestCase
  setup do
    @guest = User.create!(telegram_id: 94001, first_name: "Guest")
    @owner = User.create!(telegram_id: 94002, first_name: "Owner <&>")
    @other = User.create!(telegram_id: 94003, first_name: "Other")
    @wishlist = @owner.wishlists.create!(title: "Birthday <&>")
    @wishlist.admit!(@guest)
    @wishlist.admit!(@other)
    @api = mock("TelegramApi")
    @api.stubs(:answer_callback_query).with { |params| @answer = params; true }
    @bot = stub(api: @api)
    @edits = []
    @api.stubs(:edit_message_text).with { |params| @edits << params; true }
  end

  def book(title = "Gift <&>")
    @wishlist.items.create!(title: title, reserved_by: @guest.telegram_id)
  end

  def press(data, type: "private")
    callback = Telegram::Bot::Types::CallbackQuery.new(
      id: "bookings", chat_instance: "chat", data: data,
      from: { id: @guest.telegram_id, is_bot: false, first_name: @guest.first_name },
      message: { message_id: 1, date: 1, chat: { id: @guest.telegram_id, type: type }, text: "Menu" }
    )
    @update_id = (@update_id || 0) + 1
    Bot::Dispatcher.dispatch(@bot, Telegram::Bot::Types::Update.new(update_id: @update_id, callback_query: callback))
  end

  def buttons
    @edits.last[:reply_markup].inline_keyboard.flatten
  end

  def opened_ids
    buttons.filter_map { |button| button.callback_data[/\Aopen_booked_item:(\d+):\d+\z/, 1]&.to_i }
  end

  def text
    @edits.last.fetch(:text)
  end

  test "menu opens current bookings with owner, list, card and release actions" do
    item = book
    press("main_menu")
    assert_includes buttons.map(&:callback_data), "show_reservations"

    press("show_reservations")
    assert_equal [ item.id ], opened_ids
    row = @edits.last[:reply_markup].inline_keyboard.first
    assert_equal 1, row.size
    booked = row.first
    assert_equal "★ Gift <&> · Owner <&>", booked.text
    assert_equal "primary", booked.style
    assert_includes text, "Owner &lt;&amp;&gt; · «Birthday &lt;&amp;&gt;»"
    assert buttons.none? { |button| button.callback_data.start_with?("release_book:") }

    press(booked.callback_data)
    assert_includes buttons.map(&:callback_data), "release_book:#{item.id}:0:0"
    assert_includes buttons.map(&:callback_data), "mark_purchased:#{item.id}:0:1:0"
  end

  test "collection excludes free gifts, other people's bookings and inaccessible or owned lists" do
    mine = book
    @wishlist.items.create!(title: "Free")
    @wishlist.items.create!(title: "Other's", reserved_by: @other.telegram_id)
    hidden = @owner.wishlists.create!(title: "Hidden")
    hidden.items.create!(title: "Revoked", reserved_by: @guest.telegram_id)
    own = @guest.wishlists.create!(title: "Own")
    own.items.create!(title: "Legacy own booking", reserved_by: @guest.telegram_id)

    press("show_reservations")
    assert_equal [ mine.id ], opened_ids
    refute_includes text, "Revoked"
    refute_includes text, "Hidden"
    refute_includes text, "Other's"
    refute_includes text, "Legacy own booking"
  end

  test "pages contain five bookings, and a release clamps the last page" do
    items = 6.times.map { |index| book("Gift #{index}") }
    press("show_reservations")
    assert_equal items.first(5).map(&:id), opened_ids
    assert_includes buttons.map(&:callback_data), "show_reservations:1"

    press("show_reservations:1")
    assert_equal [ items.last.id ], opened_ids
    assert_includes buttons.map(&:callback_data), "show_reservations:0"
    refute_includes buttons.map(&:callback_data), "show_reservations:2"

    press("open_booked_item:#{items.last.id}:1")
    release = buttons.find { |button| button.callback_data.start_with?("release_book:") }.callback_data
    press(release)
    assert_nil items.last.reload.reserved_by
    assert_equal 1, items.last.reservation_version
    assert_equal items.first(5).map(&:id), opened_ids
    refute_includes text, "Страница"
    assert_equal I18n.t("bot.messages.unreserved_notice"), @answer[:text]

    press(release)
    assert_nil items.last.reload.reserved_by
    assert_equal 1, items.last.reservation_version
  end

  test "an old release button cannot remove a later booking by the same guest" do
    item = book
    item.release_for!(@guest)
    item.reserve_for!(@guest)

    press("release_book:#{item.id}:0:0")
    assert_equal @guest.telegram_id, item.reload.reserved_by
    assert_equal 2, item.reservation_version
    assert_equal I18n.t("bot.messages.reservation_changed"), @answer[:text]
    assert_equal [ item.id ], opened_ids
  end

  test "release uses the shared notification path once and never sends inline" do
    item = book
    Telegram::Bot::Client.expects(:new).never
    @api.expects(:send_message).never

    assert_enqueued_jobs 1, only: NotificationJob do
      2.times { press("release_book:#{item.id}:0:0") }
    end

    job = enqueued_jobs.find { |entry| entry[:job] == NotificationJob }
    assert_equal [ @owner.telegram_id, "own_released" ], job[:args].first(2)
    assert_includes text, I18n.t("bot.screens.reservations.empty")
    assert_nil item.reload.reserved_by
  end

  test "forged release callbacks cannot release someone else's booking" do
    item = @wishlist.items.create!(title: "Other", reserved_by: @other.telegram_id)
    press("release_book:#{item.id}:0:0")

    assert_equal @other.telegram_id, item.reload.reserved_by
    assert_equal 0, item.reservation_version
    assert_includes text, I18n.t("bot.screens.reservations.empty")
  end

  test "deleted or no longer accessible bookings refresh into a usable empty screen" do
    item = book
    ListViewer.where(wishlist: @wishlist, user: @guest).delete_all
    press("release_book:#{item.id}:0:9")
    assert_equal @guest.telegram_id, item.reload.reserved_by
    assert_includes text, I18n.t("bot.screens.reservations.empty")
    assert_equal %w[main_menu show_shared_lists], buttons.map(&:callback_data)
    assert_equal I18n.t("bot.messages.not_available"), @answer[:text]

    item.destroy!
    press("release_book:#{item.id}:0:9")
    assert_includes text, I18n.t("bot.screens.reservations.empty")
  end

  test "the card returns to its reservation page after opening from the collection" do
    items = 7.times.map { |index| book("Gift #{index}") }
    press("show_reservations:1")
    open_card = buttons.find { |button| button.callback_data == "open_booked_item:#{items.last.id}:1" }
    press(open_card.callback_data)

    assert_includes text, items.last.title
    assert_equal "show_reservations:1", buttons.last.callback_data
    assert_includes buttons.map(&:callback_data), "list_page:#{@wishlist.id}:1"
    assert_includes buttons.map(&:callback_data), "release_book:#{items.last.id}:0:1"
    assert buttons.none? { |button| button.callback_data.start_with?("open_item:", "unreserve_item:") }

    press(buttons.last.callback_data)
    assert_equal items.last(2).map(&:id), opened_ids
  end

  test "release from a card preserves the originating page and clamps an empty final page" do
    items = 7.times.map { |index| book("Gift #{index}") }
    press("open_booked_item:#{items.last.id}:1")
    release = buttons.find { |button| button.callback_data.start_with?("release_book:") }.callback_data

    2.times { press(release) }
    assert_equal [ items[-2].id ], opened_ids
    assert_includes text, "Страница 2 из 2"
    assert_nil items.last.reload.reserved_by
    assert_equal 1, items.last.reservation_version

    press("open_booked_item:#{items[-2].id}:1")
    press(buttons.find { |button| button.callback_data.start_with?("release_book:") }.callback_data)
    assert_equal items.first(5).map(&:id), opened_ids
    refute_includes text, "Страница"
  end

  test "releasing the final booking from its card returns to the empty collection once" do
    item = book
    press("open_booked_item:#{item.id}:0")
    release = buttons.find { |button| button.callback_data.start_with?("release_book:") }.callback_data
    @api.expects(:send_message).never

    assert_enqueued_jobs 1, only: NotificationJob do
      2.times { press(release) }
    end

    assert_includes text, I18n.t("bot.screens.reservations.empty")
    assert_equal %w[main_menu show_shared_lists], buttons.map(&:callback_data)
    assert_nil item.reload.reserved_by
    assert_equal 1, item.reservation_version
  end

  test "old card links refresh the collection after release, deletion or revoked access" do
    item = book
    item.release_for!(@guest)
    press("open_booked_item:#{item.id}:8")
    assert_includes text, I18n.t("bot.screens.reservations.empty")
    assert_equal I18n.t("bot.messages.button_outdated"), @answer[:text]

    item.reserve_for!(@guest)
    ListViewer.where(wishlist: @wishlist, user: @guest).delete_all
    press("open_booked_item:#{item.id}:0")
    assert_includes text, I18n.t("bot.screens.reservations.empty")
    refute_includes text, item.title
    assert_equal @guest.telegram_id, item.reload.reserved_by

    item.destroy!
    press("open_booked_item:#{item.id}:0")
    assert_includes text, I18n.t("bot.screens.reservations.empty")
  end

  test "forged card links do not expose another guest's booking or legacy owned bookings" do
    other_item = @wishlist.items.create!(title: "Other booking", reserved_by: @other.telegram_id)
    own_list = @guest.wishlists.create!(title: "My list")
    own_item = own_list.items.create!(title: "Legacy own booking", reserved_by: @guest.telegram_id)

    [ other_item, own_item ].each do |item|
      press("open_booked_item:#{item.id}:0")
      assert_includes text, I18n.t("bot.screens.reservations.empty")
      refute_includes text, item.title
      assert_equal I18n.t("bot.messages.button_outdated"), @answer[:text]
    end
  end

  test "regular wishlist cards keep neighbour navigation and release in place" do
    first, second = 2.times.map { |index| book("Gift #{index}") }
    press("open_item:#{first.id}")
    assert_includes buttons.map(&:callback_data), "open_item:#{second.id}"
    assert_includes buttons.map(&:callback_data), "unreserve_item:#{first.id}:0"
    refute buttons.any? { |button| button.callback_data.start_with?("release_book:") }

    press("unreserve_item:#{first.id}:0")
    assert_includes text, first.title
    assert_includes buttons.map(&:callback_data), "reserve_item:#{first.id}:1"
  end

  test "group callbacks never release a reservation or show the collection" do
    item = book
    @api.expects(:send_message).once
    press("release_book:#{item.id}:0:0", type: "group")

    assert_equal @guest.telegram_id, item.reload.reserved_by
    assert_empty @edits
  end

  test "long legacy data fits the Telegram message limit with escaped HTML" do
    @owner.update_columns(first_name: '"' * 6000)
    @wishlist.update_columns(title: '"' * 6000)
    5.times { book.update_columns(title: '"' * 6000) }
    press("show_reservations")

    assert_operator text.encode("UTF-16LE").bytesize / 2, :<, 4096
    assert_equal 5, opened_ids.size
    assert buttons.all? { |button| button.callback_data.bytesize <= 64 }
    assert buttons.none? { |button| button.callback_data == "noop" }
    assert buttons.select { |button| button.callback_data.start_with?("open_booked_item:") }.all? { |button| button.text.length <= 80 }
  end
end
