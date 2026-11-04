require "test_helper"
require "mocha/minitest"

class BotReservationDeletionTest < ActiveJob::TestCase
  setup do
    @owner = User.create!(telegram_id: 72001, first_name: "Owner")
    @guest = User.create!(telegram_id: 72002, first_name: "Guest")
    @other = User.create!(telegram_id: 72003, first_name: "Other")
    @wishlist = @owner.wishlists.create!(title: "Birthday")
    @wishlist.admit!(@guest)
    @wishlist.admit!(@other)
    @item = @wishlist.items.create!(title: "Puzzle")
  end

  def details
    { "list" => "Birthday", "owner" => "Owner" }
  end

  test "deleting a reserved gift queues only its reserver and repeated deletion does nothing" do
    @item.reserve_for!(@guest)

    assert_enqueued_with(job: ReservedGiftDeletedJob,
                         args: [ @guest.telegram_id, "item_deleted", details.merge("title" => "Puzzle"), "ru" ]) do
      Bot::ReservationDeletion.destroy_item!(@item)
    end
    assert_no_enqueued_jobs { Bot::ReservationDeletion.destroy_item!(@item) }
    assert_not Item.exists?(@item.id)
    assert_equal 1, enqueued_jobs.size
  end

  test "the locked snapshot includes a reservation made after the item was loaded" do
    Item.find(@item.id).reserve_for!(@guest)
    assert_nil @item.reserved_by

    assert_enqueued_with(job: ReservedGiftDeletedJob,
                         args: [ @guest.telegram_id, "item_deleted", details.merge("title" => "Puzzle"), "ru" ]) do
      Bot::ReservationDeletion.destroy_item!(@item)
    end
  end

  test "deleting an unreserved gift queues no message" do
    assert_no_enqueued_jobs { Bot::ReservationDeletion.destroy_item!(@item) }
    assert_not Item.exists?(@item.id)
  end

  test "rolling back a delete never queues a notification" do
    @item.reserve_for!(@guest)

    assert_no_enqueued_jobs do
      Item.transaction do
        Bot::ReservationDeletion.destroy_item!(@item)
        raise ActiveRecord::Rollback
      end
    end
    assert Item.exists?(@item.id)
  end

  test "deleting a list queues one message per affected guest and none to viewers or owner" do
    @item.reserve_for!(@guest)
    @wishlist.items.create!(title: "Book", reserved_by: @guest.telegram_id)
    @wishlist.items.create!(title: "Game", reserved_by: @other.telegram_id)
    @wishlist.items.create!(title: "Legacy own reservation", reserved_by: @owner.telegram_id)
    @wishlist.admit!(User.create!(telegram_id: 72004, first_name: "Viewer"))

    assert_enqueued_jobs 2 do
      Bot::ReservationDeletion.destroy_list!(@wishlist)
    end
    assert_equal [ @guest.telegram_id, @other.telegram_id ], enqueued_jobs.map { |job| job[:args].first }.sort
    assert enqueued_jobs.all? { |job| job[:args][1] == "list_deleted" }
    assert_not Wishlist.exists?(@wishlist.id)
    assert_empty Item.where(wishlist_id: @wishlist.id)
  end

  test "an enqueue failure does not report a committed deletion as failed" do
    @item.reserve_for!(@guest)
    ReservedGiftDeletedJob.expects(:perform_later).raises(ActiveJob::EnqueueError, "queue unavailable")

    assert_nothing_raised { Bot::ReservationDeletion.destroy_item!(@item) }
    assert_not Item.exists?(@item.id)
  end

  test "the delete callback acknowledges the owner without sending the guest message inline" do
    @item.reserve_for!(@guest)
    api = mock("TelegramApi")
    bot = stub(api: api)
    api.expects(:edit_message_text)
    api.expects(:answer_callback_query).with(callback_query_id: "delete", text: I18n.t("bot.messages.item_deleted_success"))
    api.expects(:send_message).never
    Telegram::Bot::Client.expects(:new).never
    callback = Telegram::Bot::Types::CallbackQuery.new(
      id: "delete", chat_instance: "chat", data: "delete_item:#{@item.id}",
      from: { id: @owner.telegram_id, is_bot: false, first_name: "Owner" },
      message: { message_id: 1, date: 1, chat: { id: @owner.telegram_id, type: "private" }, text: "Gift" }
    )

    assert_enqueued_jobs 1 do
      Bot::Dispatcher.dispatch(bot, Telegram::Bot::Types::Update.new(update_id: 1, callback_query: callback))
    end
    assert_not Item.exists?(@item.id)
  end
end
