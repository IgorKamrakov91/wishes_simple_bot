require "test_helper"
require "mocha/minitest"

class BirthdayRemindersTest < ActiveJob::TestCase
  setup do
    travel_to Time.utc(2026, 11, 6, 9)
    @previous_token = ENV["TELEGRAM_BOT_TOKEN"]
    ENV["TELEGRAM_BOT_TOKEN"] = "local-birthday-test"
    @guest = User.create!(telegram_id: 98201, first_name: "Guest")
    @owner = User.create!(telegram_id: 98202, first_name: "Birthday Person")
    @lists = 2.times.map { |i| @owner.wishlists.create!(title: "Shared #{i}").tap { |list| list.admit!(@guest) } }
    @hidden = @owner.wishlists.create!(title: "Private list")
    @messages = []
    @api = mock("TelegramApi")
    @api.stubs(:send_message).with { |params| @messages << params; true }
    profile(day: 6, month: 12)
    Telegram::Bot::Client.stubs(:new).returns(stub(api: @api))
  end

  teardown do
    ENV["TELEGRAM_BOT_TOKEN"] = @previous_token
    travel_back
  end

  def profile(day: nil, month: nil)
    birthdate = stub(day: day, month: month, year: 1987) if day && month
    @api.stubs(:get_chat).with(chat_id: @owner.telegram_id).returns(stub(type: "private", birthdate: birthdate))
  end

  def sync
    SyncTelegramBirthdayJob.perform_now(@owner.id)
  end

  def delivery
    BirthdayReminderDelivery.find_by!(recipient: @guest, owner: @owner)
  end

  def send_reminder
    BirthdayReminderJob.perform_now(delivery.id)
  end

  def response_error(code, **extra)
    body = { "ok" => false, "error_code" => code, "description" => "Private Telegram response" }.merge(extra.stringify_keys)
    Telegram::Bot::Exceptions::ResponseError.new(response: stub(status: code, body: body.to_json))
  end

  test "one reminder covers multiple shared lists and stores no birth year" do
    @api.expects(:get_chat).once.with(chat_id: @owner.telegram_id).returns(
      stub(type: "private", birthdate: stub(day: 6, month: 12, year: 1987))
    )
    2.times { sync }
    assert_equal [ 6, 12 ], @owner.reload.attributes.values_at("birthdate_day", "birthdate_month")
    assert_equal 1, BirthdayReminderDelivery.count
    refute User.column_names.include?("birthdate_year")

    2.times { send_reminder }
    assert_equal 1, @messages.size
    message = @messages.sole
    assert_equal @guest.telegram_id, message[:chat_id]
    assert_includes message[:text], "Birthday Person — 06.12"
    refute_includes message[:text], "1987"
    callbacks = message[:reply_markup].inline_keyboard.flatten.map(&:callback_data)
    assert_equal @lists.map { |list| "open_list:#{list.id}" } + %w[show_shared_lists settings], callbacks
    refute_includes callbacks, "open_list:#{@hidden.id}"
    assert_equal Time.current, delivery.sent_at
    assert_equal 1, delivery.attempts
  end

  test "lists with free gifts come first and the text doesn't promise free gifts when there are none" do
    empty, reserved = @lists
    reserved.items.create!(title: "Taken", reserved_by: @guest.telegram_id)
    free = 2.times.map do |i|
      @owner.wishlists.create!(title: "Free #{i}").tap { |list| list.admit!(@guest); list.items.create!(title: "Gift") }
    end
    sync
    send_reminder

    message = @messages.sole
    callbacks = message[:reply_markup].inline_keyboard.flatten.map(&:callback_data)
    assert_equal [ *free, reserved ].map { |list| "open_list:#{list.id}" }, callbacks.first(3)
    refute_includes callbacks, "open_list:#{empty.id}"
    assert_equal I18n.t("bot.reminders.birthdays.text", name: "Birthday Person", date: "06.12"), message[:text]
  end

  test "when every shared gift is reserved the reminder says so instead of promising a choice" do
    @lists.first.items.create!(title: "Taken", reserved_by: @guest.telegram_id)
    sync
    send_reminder

    assert_equal I18n.t("bot.reminders.birthdays.text_nothing_free", name: "Birthday Person", date: "06.12"),
                 @messages.sole[:text]
  end

  test "the daily scheduler fetches only owners with interested guests" do
    User.create!(telegram_id: 98203)
    quiet_owner = User.create!(telegram_id: 98204)
    quiet_guest = User.create!(telegram_id: 98205, notify_birthdays: false)
    quiet_owner.wishlists.create!(title: "Quiet").admit!(quiet_guest)

    assert_enqueued_jobs 1, only: SyncTelegramBirthdayJob do
      BirthdayRemindersJob.perform_now
    end
    assert_equal [ @owner.id ], enqueued_jobs.find { |job| job[:job] == SyncTelegramBirthdayJob }[:args]
  end

  test "an omitted or invalid profile date clears old data and suppresses queued delivery" do
    sync
    travel_to 1.day.from_now
    profile
    sync
    assert_nil @owner.reload.birthdate_day
    assert_nil @owner.birthdate_month
    send_reminder
    assert_empty @messages

    travel_to 1.day.from_now
    profile(day: 31, month: 2)
    sync
    assert_nil @owner.reload.birthdate_day
  end

  test "a failed daily refresh makes cached birthdays ineligible and retries respect rate limits" do
    sync
    clear_enqueued_jobs
    travel_to 1.day.from_now
    @api.expects(:get_chat).once.raises(response_error(429, parameters: { "retry_after" => 90 }))
    retry_at = 90.seconds.from_now

    assert_enqueued_with(job: SyncTelegramBirthdayJob, args: [ @owner.id, Time.current.iso8601(6), 1 ], at: retry_at) { sync }
    assert_nil @owner.reload.birthdate_synced_at
    send_reminder
    assert_empty @messages

    travel_to retry_at
    SyncTelegramBirthdayJob.perform_now(@owner.id, @owner.birthdate_checked_at.iso8601(6), 1)
    assert_equal Time.current, @owner.reload.birthdate_synced_at
    send_reminder
    assert_equal 1, @messages.size
  end

  test "birthday opt-out and revoked list access are rechecked after enqueue" do
    sync
    @guest.update!(notify_birthdays: false)
    send_reminder
    assert_empty @messages
    assert_nil delivery.claimed_at

    @guest.update!(notify_birthdays: true)
    @lists.each { |list| list.list_viewers.where(user: @guest).delete_all }
    send_reminder
    assert_empty @messages
    assert_nil delivery.claimed_at
  end

  test "the occurrence year deduplicates a January birthday across December and January" do
    travel_to Time.utc(2026, 12, 20, 9)
    profile(day: 6, month: 1)
    sync
    send_reminder
    assert_equal 2027, delivery.birthday_year

    travel_to Time.utc(2027, 1, 1, 9)
    sync
    send_reminder
    assert_equal 1, @messages.size
    assert_equal 1, BirthdayReminderDelivery.count
  end

  test "February 29 has a reminder in leap and non-leap years without changing the profile date" do
    profile(day: 29, month: 2)
    [ [ 2027, 1, 29 ], [ 2028, 1, 30 ] ].each do |year, month, day|
      travel_to Time.utc(year, month, day, 9)
      sync
      current = BirthdayReminderDelivery.find_by!(birthday_year: year)
      BirthdayReminderJob.perform_now(current.id)
      assert_equal 29, @owner.reload.birthdate_day
      assert_includes @messages.last[:text], "29.02"
    end
    assert_equal 2, @messages.size
  end

  test "a late queue run and a new guest are caught up inside the 30 day window" do
    sync
    travel_to Time.utc(2026, 11, 20, 9)
    newcomer = User.create!(telegram_id: 98206)
    @lists.first.admit!(newcomer)
    sync
    BirthdayReminderDelivery.find_each { |record| BirthdayReminderJob.perform_now(record.id) }
    assert_equal [ @guest.telegram_id, newcomer.telegram_id ].sort, @messages.map { |message| message[:chat_id] }.sort
  end

  test "expired birthday jobs do not announce next year's birthday early" do
    sync
    travel_to Time.utc(2026, 12, 7, 9)
    sync
    send_reminder
    assert_empty @messages
    assert_nil delivery.claimed_at
  end

  test "duplicate jobs during a send cannot claim the same annual reminder" do
    sync
    @api.expects(:send_message).once.with { |_params| send_reminder; true }
    send_reminder
    assert_equal 1, delivery.attempts
    assert_equal Time.current, delivery.sent_at
  end

  test "birthday delivery uses retry_after and retries the same annual record" do
    sync
    clear_enqueued_jobs
    @api.expects(:send_message).once.raises(response_error(429, parameters: { "retry_after" => 90 }))
    retry_at = 90.seconds.from_now
    assert_enqueued_with(job: BirthdayReminderJob, args: [ delivery.id ], at: retry_at) { send_reminder }
    assert_nil delivery.sent_at
    assert_nil delivery.claimed_at
    assert_equal 1, delivery.attempts
    @messages.clear
    travel_to retry_at
    send_reminder
    assert_equal Time.current, delivery.sent_at
    assert_equal 2, delivery.attempts
    assert_equal 1, @messages.size
  end

  test "a timeout leaves the annual attempt claimed and a blocked bot is not retried" do
    sync
    clear_enqueued_jobs
    @api.expects(:send_message).once.raises(Faraday::TimeoutError)
    assert_no_enqueued_jobs { 2.times { send_reminder } }
    assert_nil delivery.sent_at
    assert_equal 1, delivery.attempts

    other = User.create!(telegram_id: 98207)
    @lists.first.admit!(other)
    BirthdayReminders.dispatch_for(@owner.reload)
    record = BirthdayReminderDelivery.find_by!(recipient: other)
    clear_enqueued_jobs
    @api.expects(:send_message).once.raises(response_error(403))
    assert_no_enqueued_jobs { BirthdayReminderJob.perform_now(record.id) }
    assert_nil record.reload.sent_at
    assert record.claimed_at
  end

  test "a late delivery waits for daytime and requires a fresh profile the next day" do
    sync
    clear_enqueued_jobs
    travel_to Time.utc(2026, 11, 6, 20)
    opening = Time.utc(2026, 11, 7, 9)
    assert_enqueued_with(job: BirthdayReminderJob, args: [ delivery.id ], at: opening) { send_reminder }
    assert_empty @messages

    travel_to opening
    send_reminder
    assert_empty @messages
    sync
    send_reminder
    assert_equal 1, @messages.size
  end

  test "deleted accounts cascade the ledger and queued jobs do nothing" do
    sync
    id = delivery.id
    @guest.destroy!
    assert_nil BirthdayReminderDelivery.find_by(id: id)
    BirthdayReminderJob.perform_now(id)
    assert_empty @messages
  end

  test "definite delivery failures stop after three attempts for the annual record" do
    sync
    clear_enqueued_jobs
    @api.expects(:send_message).times(3).raises(response_error(503))
    3.times do |index|
      assert_enqueued_jobs(index < 2 ? 1 : 0) { send_reminder }
      travel_to 30.seconds.from_now
    end
    assert_equal 3, delivery.attempts
    assert_nil delivery.sent_at
    send_reminder
    assert_equal 3, delivery.attempts
  end

  test "a blocked profile refresh invalidates the cache without retry or raw response logs" do
    sync
    clear_enqueued_jobs
    travel_to 1.day.from_now
    @api.expects(:get_chat).once.raises(response_error(403))
    Rails.logger.stubs(:info)
    Rails.logger.expects(:info).with("Telegram birthday refresh failed (403)")

    assert_no_enqueued_jobs { sync }
    send_reminder
    assert_empty @messages
    assert_nil @owner.reload.birthdate_synced_at
  end
end
