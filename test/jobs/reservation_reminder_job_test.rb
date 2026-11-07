require "test_helper"
require "mocha/minitest"

class ReservationReminderJobTest < ActiveJob::TestCase
  setup do
    travel_to Time.utc(2026, 11, 6, 9) # noon in Moscow
    @previous_token = ENV["TELEGRAM_BOT_TOKEN"]
    ENV["TELEGRAM_BOT_TOKEN"] = "local-reminder-test"
    @guest = User.create!(telegram_id: 98001, first_name: "Guest")
    @owner = User.create!(telegram_id: 98002, first_name: "Owner")
    @wishlist = @owner.wishlists.create!(title: "Birthday")
    @wishlist.admit!(@guest)
    @item = @wishlist.items.create!(title: "Puzzle", reserved_by: @guest.telegram_id)
    @guest.update!(reservation_reminder_days: 7, reservation_reminder_next_at: Time.current)
    @due_at = @guest.reservation_reminder_next_at.iso8601(6)
    @messages = []
    @api = mock("TelegramApi")
    @api.stubs(:send_message).with { |params| @messages << params; true }
    Telegram::Bot::Client.stubs(:new).returns(stub(api: @api))
  end

  teardown do
    ENV["TELEGRAM_BOT_TOKEN"] = @previous_token
    travel_back
  end

  def deliver(attempt = 0)
    ReservationReminderJob.perform_now(@guest.id, @due_at, attempt)
  end

  def response_error(code, **extra)
    body = { "ok" => false, "error_code" => code, "description" => "Delivery failed" }.merge(extra.stringify_keys)
    Telegram::Bot::Exceptions::ResponseError.new(response: stub(status: code, body: body.to_json))
  end

  test "only accessible unpurchased bookings appear in one digest" do
    @wishlist.items.create!(title: "Bought", reserved_by: @guest.telegram_id, purchased_at: Time.current)
    @wishlist.items.create!(title: "Someone else's", reserved_by: @owner.telegram_id)
    hidden = @owner.wishlists.create!(title: "Hidden")
    hidden.items.create!(title: "Revoked", reserved_by: @guest.telegram_id)
    own = @guest.wishlists.create!(title: "Owned")
    own.items.create!(title: "Legacy own booking", reserved_by: @guest.telegram_id)

    deliver
    assert_equal 1, @messages.size
    message = @messages.sole
    assert_equal @guest.telegram_id, message[:chat_id]
    assert_includes message[:text], "Puzzle — Owner, «Birthday»"
    %w[Bought Revoked Owned Someone].each { |name| refute_includes message[:text], name }
    assert_equal %w[show_reservations settings], message[:reply_markup].inline_keyboard.flatten.map(&:callback_data)
    assert_equal Time.current, @guest.reload.reservation_reminder_last_sent_at
    assert_equal 7.days.from_now, @guest.reservation_reminder_next_at
  end

  test "a duplicate delivery, including one while Telegram is being called, cannot send twice" do
    @api.expects(:send_message).once.with do |_params|
      deliver
      true
    end

    deliver
    deliver
    assert_equal Time.current, @guest.reload.reservation_reminder_last_attempt_at
  end

  test "disabling or changing the interval invalidates an already queued delivery" do
    @api.expects(:send_message).never
    @guest.configure_reservation_reminders!(0)
    deliver
    @guest.configure_reservation_reminders!(14)
    deliver

    assert_nil @guest.reload.reservation_reminder_last_sent_at
    assert_equal 14.days.from_now, @guest.reservation_reminder_next_at
  end

  test "buying or losing access after enqueue leaves nothing to send" do
    @api.expects(:send_message).never
    @item.mark_purchased_by!(@guest, true)
    deliver
    @item.mark_purchased_by!(@guest, false)
    @wishlist.list_viewers.where(user: @guest).delete_all
    deliver

    assert_nil @guest.reload.reservation_reminder_last_attempt_at
    assert_nil @guest.reservation_reminder_last_sent_at
  end

  test "a deleted recipient or a future due time is skipped" do
    @api.expects(:send_message).never
    ReservationReminderJob.perform_now(@guest.id, 1.day.from_now.iso8601(6))
    @guest.destroy!
    deliver
  end

  test "late jobs wait for the next daytime window in Moscow" do
    travel_to Time.utc(2026, 11, 6, 20) # 23:00 Moscow
    opening = Time.utc(2026, 11, 7, 9)
    @api.expects(:send_message).never

    assert_enqueued_with(job: ReservationReminderJob, args: [ @guest.id, opening.iso8601(6), 0 ], at: opening) { deliver }
    assert_nil @guest.reload.reservation_reminder_last_attempt_at
    assert_equal opening, @guest.reservation_reminder_next_at
  end

  test "rate limits reschedule using retry_after and do not count as a sent reminder" do
    @api.expects(:send_message).once.raises(response_error(429, parameters: { "retry_after" => 90 }))
    retry_at = 90.seconds.from_now

    assert_enqueued_with(job: ReservationReminderJob, args: [ @guest.id, retry_at.iso8601(6), 1 ], at: retry_at) { deliver }
    assert_nil @guest.reload.reservation_reminder_last_sent_at
    assert_equal retry_at, @guest.reservation_reminder_next_at
    @messages.clear
    @due_at = retry_at.iso8601(6)
    travel_to retry_at
    deliver(1)
    assert_equal 1, @messages.size
    assert_equal retry_at, @guest.reload.reservation_reminder_last_sent_at
  end

  test "a blocked bot and an ambiguous timeout are not retried immediately" do
    @api.expects(:send_message).once.raises(response_error(403))
    assert_no_enqueued_jobs { deliver }
    assert_nil @guest.reload.reservation_reminder_last_sent_at
    assert_equal 7.days.from_now, @guest.reservation_reminder_next_at

    @guest.update!(reservation_reminder_next_at: Time.current)
    @api.expects(:send_message).once.raises(Faraday::TimeoutError)
    assert_no_enqueued_jobs { 2.times { deliver } }
    assert_nil @guest.reload.reservation_reminder_last_sent_at
  end

  test "retrying stops at the third definitive failure" do
    @api.expects(:send_message).once.raises(response_error(503))
    assert_no_enqueued_jobs { deliver(2) }
    assert_equal 7.days.from_now, @guest.reload.reservation_reminder_next_at
  end

  test "changing settings during a failed request is not overwritten by retry scheduling" do
    @api.expects(:send_message).once.with do |_params|
      @guest.configure_reservation_reminders!(0)
      true
    end.raises(response_error(429, parameters: { "retry_after" => 90 }))

    assert_no_enqueued_jobs { deliver }
    assert_equal 0, @guest.reload.reservation_reminder_days
    assert_nil @guest.reservation_reminder_next_at
  end

  test "the scheduler finds only enabled and due users" do
    User.create!(telegram_id: 98003, reservation_reminder_days: 14, reservation_reminder_next_at: 1.day.from_now)
    User.create!(telegram_id: 98004, reservation_reminder_next_at: Time.current)

    assert_enqueued_with(job: ReservationReminderJob, args: [ @guest.id, @due_at ]) do
      assert_enqueued_jobs(1) { ReservationRemindersJob.perform_now }
    end
  end

  test "an afternoon opt-in is due at noon after seven Moscow calendar days" do
    @guest.configure_reservation_reminders!(0)
    travel_to Time.utc(2026, 11, 6, 12, 37) # 15:37 Moscow
    @guest.configure_reservation_reminders!(7)
    noon = Time.utc(2026, 11, 13, 9)
    assert_equal noon, @guest.reload.reservation_reminder_next_at

    travel_to noon
    assert_enqueued_jobs 1, only: ReservationReminderJob do
      ReservationRemindersJob.perform_now
    end
    job = enqueued_jobs.find { |entry| entry[:job] == ReservationReminderJob }
    ReservationReminderJob.perform_now(*job[:args])
    assert_equal 1, @messages.size
  end

  test "send time seconds do not postpone eligibility beyond the next daily run" do
    travel_to Time.utc(2026, 11, 6, 9, 0, 3)
    deliver
    assert_equal Time.utc(2026, 11, 6, 9, 0, 3), @guest.reload.reservation_reminder_last_sent_at
    next_noon = Time.utc(2026, 11, 13, 9)
    assert_equal next_noon, @guest.reservation_reminder_next_at

    travel_to next_noon
    assert_enqueued_jobs(1) { ReservationRemindersJob.perform_now }
  end

  test "large legacy titles stay within the message limit and the digest is bounded" do
    @item.update_column(:title, "🔥" * 6000)
    @wishlist.update_column(:title, "🔥" * 6000)
    6.times { |index| @wishlist.items.create!(title: "Gift #{index}", reserved_by: @guest.telegram_id) }

    deliver
    assert_operator @messages.sole[:text].encode("UTF-16LE").bytesize / 2, :<, 4096
    assert_equal 5, @messages.sole[:text].lines.count { |line| line.start_with?("•") }
    assert_includes @messages.sole[:text], "И ещё 2"
  end
end
