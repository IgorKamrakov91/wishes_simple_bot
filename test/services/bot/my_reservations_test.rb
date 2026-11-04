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
    Bot::Dispatcher.dispatch(@bot, Telegram::Bot::Types::Update.new(update_id: 1, callback_query: callback))
  end

  def buttons
    @edits.last[:reply_markup].inline_keyboard.flatten
  end

  def opened_ids
    buttons.filter_map { |button| button.callback_data[/\Aopen_item:(\d+)\z/, 1]&.to_i }
  end

  def text
    @edits.last.fetch(:text)
  end

  test "menu opens current bookings with owner, list, card and release actions" do
    item = book
    press("main_menu")
    assert_includes buttons.map(&:callback_data), "show_reservations"

    press("show_reservations")
    assert_includes text, "Gift &lt;&amp;&gt;"
    assert_includes text, "Owner &lt;&amp;&gt;"
    assert_includes text, "Birthday &lt;&amp;&gt;"
    refute_includes text, "Gift <&>"
    assert_equal [ item.id ], opened_ids
    assert_includes buttons.map(&:callback_data), "release_book:#{item.id}:0:0"
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

    release = buttons.find { |button| button.callback_data.start_with?("release_book:") }.callback_data
    press(release)
    assert_nil items.last.reload.reserved_by
    assert_equal 1, items.last.reservation_version
    assert_equal items.first(5).map(&:id), opened_ids
    assert_includes text, "Страница 1 из 1"
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
    assert_includes buttons.map(&:callback_data), "release_book:#{item.id}:2:0"
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
    assert_equal %w[show_shared_lists main_menu], buttons.map(&:callback_data)
    assert_equal I18n.t("bot.messages.not_available"), @answer[:text]

    item.destroy!
    press("release_book:#{item.id}:0:9")
    assert_includes text, I18n.t("bot.screens.reservations.empty")
  end

  test "the card returns to its reservation page after opening from the collection" do
    items = 7.times.map { |index| book("Gift #{index}") }
    press("open_item:#{items.last.id}")
    assert_equal "show_reservations:1", buttons.last.callback_data
    press(buttons.last.callback_data)
    assert_equal items.last(2).map(&:id), opened_ids
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
    assert_includes text, "&quot;"
  end
end
