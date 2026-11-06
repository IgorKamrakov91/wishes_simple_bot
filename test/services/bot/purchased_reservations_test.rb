require "test_helper"
require "mocha/minitest"
require "telegram/bot"

# Load the gem's types the way real updates do
Telegram::Bot::Types::Update

# "Already bought" belongs to the guest's reservation: only that guest sees
# and changes it, and it ends with the reservation
class BotPurchasedReservationsTest < ActiveSupport::TestCase
  setup do
    @guest = User.create!(telegram_id: 95001, first_name: "Guest")
    @owner = User.create!(telegram_id: 95002, first_name: "Owner")
    @other = User.create!(telegram_id: 95003, first_name: "Other")
    @wishlist = @owner.wishlists.create!(title: "Birthday")
    @wishlist.admit!(@guest)
    @wishlist.admit!(@other)
    @item = @wishlist.items.create!(title: "Puzzle")
    @item.reserve_for!(@guest)

    @api = mock("TelegramApi")
    @api.stubs(:answer_callback_query).with { |params| @answer = params; true }
    @api.stubs(:send_message)
    @edits = []
    @api.stubs(:edit_message_text).with { |params| @edits << params; true }
    @bot = stub(api: @api)
  end

  test "the guest marks a booking bought from My reservations and can undo it" do
    press("show_reservations")
    press(buttons.first.callback_data)
    mark = "mark_purchased:#{@item.id}:1:1:0"
    assert_includes callbacks, mark

    2.times { press(mark) }
    assert @item.reload.purchased?
    assert_equal I18n.t("bot.messages.purchased_notice"), @answer[:text]
    assert_includes text, I18n.t("bot.screens.item.guest_purchased")
    assert_includes callbacks, "mark_purchased:#{@item.id}:2:0:0"
    assert_includes callbacks, "show_reservations:0"

    press("show_reservations")
    assert_equal "Puzzle · Owner, «Birthday» · куплен", buttons.first.text

    press("mark_purchased:#{@item.id}:2:0:0")
    refute @item.reload.purchased?
    assert_equal I18n.t("bot.messages.not_purchased_notice"), @answer[:text]
  end

  test "releasing ends the mark, and an old button can't mark the next reservation" do
    press("mark_purchased:#{@item.id}:1:1")
    refute @item.release_for!(@guest, expected_version: 1), "a release button from before the mark is outdated"
    assert @item.release_for!(@guest, expected_version: 2)
    assert_nil @item.reload.purchased_at

    @item.reserve_for!(@guest)
    press("mark_purchased:#{@item.id}:1:1")
    refute @item.reload.purchased?
    assert_equal I18n.t("bot.messages.button_outdated"), @answer[:text]
  end

  test "a late repeat of an earlier press can't undo a later choice" do
    press("mark_purchased:#{@item.id}:1:1")
    press("mark_purchased:#{@item.id}:2:0")
    press("mark_purchased:#{@item.id}:1:1")
    refute @item.reload.purchased?
    assert_equal I18n.t("bot.messages.button_outdated"), @answer[:text]

    press("mark_purchased:#{@item.id}:3:1")
    press("mark_purchased:#{@item.id}:2:0")
    assert @item.reload.purchased?
    assert_equal 4, @item.reservation_version
  end

  test "nobody else can mark the booking, and the owner never sees the mark" do
    press("mark_purchased:#{@item.id}:1:1", as: @other)
    refute @item.reload.purchased?
    press("mark_purchased:#{@item.id}:1:1", as: @owner)
    refute @item.reload.purchased?

    press("open_item:#{@item.id}", as: @owner)
    before = text
    @item.mark_purchased_by!(@guest, true, expected_version: 1)
    press("open_item:#{@item.id}", as: @owner)
    assert_equal before, text
    refute_includes callbacks, "mark_purchased:#{@item.id}:1:0"
  end

  test "a mark from a My reservations card after the booking ended returns to the collection" do
    @item.release_for!(@guest, expected_version: 1)
    press("mark_purchased:#{@item.id}:1:1:0")

    refute @item.reload.purchased?
    assert_includes text, I18n.t("bot.screens.reservations.empty")
  end

  private

  def press(data, as: @guest)
    callback = Telegram::Bot::Types::CallbackQuery.new(
      id: "bought", chat_instance: "chat", data: data,
      from: { id: as.telegram_id, is_bot: false, first_name: as.first_name },
      message: { message_id: 1, date: 1, chat: { id: as.telegram_id, type: "private" }, text: "Screen" }
    )
    Bot::Dispatcher.dispatch(@bot, Telegram::Bot::Types::Update.new(update_id: 1, callback_query: callback))
  end

  def text
    @edits.last.fetch(:text)
  end

  def buttons
    @edits.last[:reply_markup].inline_keyboard.flatten
  end

  def callbacks
    buttons.map(&:callback_data)
  end
end
