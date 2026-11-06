require "test_helper"
require "mocha/minitest"
require "telegram/bot"

Telegram::Bot::Types::Update

class BotReservationReminderSettingsTest < ActiveSupport::TestCase
  setup do
    travel_to Time.utc(2026, 11, 6, 9)
    @user = User.create!(telegram_id: 98101, first_name: "Guest")
    @screens = []
    @api = mock("TelegramApi")
    @api.stubs(:answer_callback_query)
    @api.stubs(:edit_message_text).with { |params| @screens << params; true }
    @bot = stub(api: @api)
  end

  teardown { travel_back }

  def press(data)
    callback = Telegram::Bot::Types::CallbackQuery.new(
      id: "reminder-settings", chat_instance: "chat", data: data,
      from: { id: @user.telegram_id, is_bot: false, first_name: @user.first_name },
      message: { message_id: 1, date: 1, chat: { id: @user.telegram_id, type: "private" }, text: "Settings" }
    )
    Bot::Callbacks.handle(@bot, callback)
  end

  def buttons
    @screens.last[:reply_markup].inline_keyboard.flatten
  end

  test "reminders start off and every supported interval is explicitly selectable" do
    assert_equal 0, @user.reservation_reminder_days
    press("settings")
    assert_includes buttons.map(&:callback_data), "reservation_reminders"
    press("reservation_reminders")
    assert_equal %w[set_reminder_days:0 set_reminder_days:7 set_reminder_days:14 set_reminder_days:30 settings], buttons.map(&:callback_data)

    [ 7, 14, 30 ].each do |days|
      press("set_reminder_days:#{days}")
      assert_equal days, @user.reload.reservation_reminder_days
      assert_equal days.days.from_now, @user.reservation_reminder_next_at
    end
    press("set_reminder_days:0")
    assert_nil @user.reload.reservation_reminder_next_at
  end

  test "repeating a preference does not postpone reminders or discard a draft" do
    @user.start_creating_list!
    press("set_reminder_days:7")
    expected = @user.reload.reservation_reminder_next_at
    travel_to 1.day.from_now
    press("settings")
    press("reservation_reminders")
    press("set_reminder_days:7")

    assert_equal expected, @user.reload.reservation_reminder_next_at
    assert_equal "creating_list", @user.bot_state
    assert_includes buttons.map(&:callback_data), "resume_input"
  end

  test "an unsupported interval cannot change the preference" do
    press("set_reminder_days:1")
    assert_equal 0, @user.reload.reservation_reminder_days
    assert_raises(ArgumentError) { @user.configure_reservation_reminders!(1) }
  end
end
