require "test_helper"
require "mocha/minitest"
require "telegram/bot"

# Load the gem's types the way real updates do
Telegram::Bot::Types::Update

# The owner thanks whoever reserved a gift without learning who it is:
# the bot passes the thanks on, once per reservation
class BotThankReserverTest < ActiveJob::TestCase
  setup do
    @owner = User.create!(telegram_id: 96001, first_name: "Owner", notify_own_reservations: false)
    @guest = User.create!(telegram_id: 96002, first_name: "Guest", username: "secret_guest",
                          notify_friend_reservations: false)
    @other = User.create!(telegram_id: 96003, first_name: "Other")
    @wishlist = @owner.wishlists.create!(title: "Birthday")
    @wishlist.admit!(@guest)
    @wishlist.admit!(@other)
    @item = @wishlist.items.create!(title: "Puzzle")

    @api = mock("TelegramApi")
    @api.stubs(:answer_callback_query).with { |params| @answer = params; true }
    @api.stubs(:send_message)
    @edits = []
    @api.stubs(:edit_message_text).with { |params| @edits << params; true }
    @bot = stub(api: @api)
  end

  test "a free gift has no thanks button" do
    press("open_item:#{@item.id}", as: @owner)

    refute callbacks.any? { |data| data.to_s.start_with?("thank_reserver") }
  end

  test "the owner thanks the reserver once, without learning who it is" do
    @item.reserve_for!(@guest)
    press("open_item:#{@item.id}", as: @owner)
    thank = "thank_reserver:#{@item.id}:1"
    assert_includes callbacks, thank

    assert_enqueued_jobs 1, only: NotificationJob do
      2.times { press(thank, as: @owner) }
    end

    job = enqueued_jobs.find { |queued| queued["job_class"] == "NotificationJob" }
    assert_equal [ @guest.telegram_id, "thanks" ], job["arguments"].first(2)
    assert_equal I18n.t("bot.messages.thanked_notice"), @answer[:text]
    assert_includes text, I18n.t("bot.screens.item.owner_thanked")
    refute_includes callbacks, thank
    refute_includes text, "secret_guest"
    refute_includes text, "Guest"
  end

  test "thanks are not for guests or for gifts in someone else's list" do
    @item.reserve_for!(@guest)

    assert_no_enqueued_jobs only: NotificationJob do
      press("thank_reserver:#{@item.id}:1", as: @other)
    end
    refute @item.reload.thanked?
  end

  test "a new reservation can be thanked again, and an old button can't thank it" do
    @item.reserve_for!(@guest)
    press("thank_reserver:#{@item.id}:1", as: @owner)
    @item.release_for!(@guest, expected_version: 1)
    @item.reserve_for!(@other, expected_version: 2)
    refute @item.reload.thanked?

    assert_no_enqueued_jobs only: NotificationJob do
      press("thank_reserver:#{@item.id}:1", as: @owner)
    end
    assert_equal I18n.t("bot.messages.reservation_changed"), @answer[:text]
    assert_includes callbacks, "thank_reserver:#{@item.id}:3"

    assert_enqueued_with(job: NotificationJob, args: ->(args) { args.first(2) == [ @other.telegram_id, "thanks" ] }) do
      press("thank_reserver:#{@item.id}:3", as: @owner)
    end
  end

  test "the thanks message names the owner and opens the gift, with no settings button" do
    @item.reserve_for!(@guest)
    details = { "wishlist_id" => @wishlist.id, "item_id" => @item.id, "title" => "Puzzle", "list" => "Birthday", "owner" => "Owner" }
    ENV.stubs(:fetch).with("TELEGRAM_BOT_TOKEN").returns("local-thanks-test")
    Telegram::Bot::Client.stubs(:new).returns(stub(api: @api))
    sent = nil
    @api.expects(:send_message).with { |params| sent = params; true }

    NotificationJob.perform_now(@guest.telegram_id, "thanks", details, "ru")

    assert_equal "💌 Owner говорит спасибо за бронь подарка «Puzzle» из списка «Birthday».", sent[:text]
    assert_equal [ "open_item:#{@item.id}" ], sent[:reply_markup].inline_keyboard.flatten.map(&:callback_data)
  end

  private

  def press(data, as:)
    callback = Telegram::Bot::Types::CallbackQuery.new(
      id: "thanks", chat_instance: "chat", data: data,
      from: { id: as.telegram_id, is_bot: false, first_name: as.first_name },
      message: { message_id: 1, date: 1, chat: { id: as.telegram_id, type: "private" }, text: "Screen" }
    )
    @update_id = (@update_id || 0) + 1
    Bot::Dispatcher.dispatch(@bot, Telegram::Bot::Types::Update.new(update_id: @update_id, callback_query: callback))
  end

  def text
    @edits.last.fetch(:text)
  end

  def callbacks
    @edits.last[:reply_markup].inline_keyboard.flatten.map(&:callback_data)
  end
end
