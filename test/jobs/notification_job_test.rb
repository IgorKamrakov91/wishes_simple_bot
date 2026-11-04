require "test_helper"
require "mocha/minitest"

class NotificationJobTest < ActiveJob::TestCase
  setup do
    @previous_token = ENV["TELEGRAM_BOT_TOKEN"]
    ENV["TELEGRAM_BOT_TOKEN"] = "local-notification-test"
    @guest = User.create!(telegram_id: 73001, first_name: "Guest")
    @details = { "title" => "Puzzle", "list" => "Birthday" }
    @api = mock("TelegramApi")
    Telegram::Bot::Client.stubs(:new).returns(stub(api: @api))
  end

  teardown do
    ENV["TELEGRAM_BOT_TOKEN"] = @previous_token
  end

  def arguments
    [ @guest.telegram_id, "own_reserved", @details, "ru" ]
  end

  def response_error(code, **extra)
    body = { "ok" => false, "error_code" => code, "description" => "Delivery failed" }.merge(extra.stringify_keys)
    Telegram::Bot::Exceptions::ResponseError.new(response: stub(status: code, body: body.to_json))
  end

  test "delivery uses the captured locale and sends to the recipient" do
    text = I18n.with_locale(:ru) { I18n.t("bot.notifications.own_reserved", **@details.symbolize_keys) }
    @api.expects(:send_message).once.with(chat_id: @guest.telegram_id, text: text)

    I18n.with_locale(:en) { NotificationJob.perform_now(*arguments) }
  end

  test "a recipient who deleted their account is skipped" do
    @guest.destroy!
    Telegram::Bot::Client.expects(:new).never

    assert_no_enqueued_jobs { NotificationJob.perform_now(*arguments) }
  end

  test "a blocked bot is not retried" do
    @api.expects(:send_message).once.raises(response_error(403))

    assert_no_enqueued_jobs { NotificationJob.perform_now(*arguments) }
  end

  test "temporary network errors are retried in the notification queue" do
    @api.expects(:send_message).once.raises(Faraday::TimeoutError)

    travel_to Time.utc(2026, 11, 4, 12) do
      assert_enqueued_with(job: NotificationJob, args: arguments, queue: "notifications", at: 30.seconds.from_now) do
        NotificationJob.perform_now(*arguments)
      end
    end
  end

  test "Telegram rate limits use its retry_after delay" do
    @api.expects(:send_message).once.raises(response_error(429, parameters: { "retry_after" => 90 }))

    travel_to Time.utc(2026, 11, 4, 12) do
      assert_enqueued_with(job: NotificationJob, args: arguments, at: 90.seconds.from_now) do
        NotificationJob.perform_now(*arguments)
      end
    end
  end

  test "delivery stops after three attempts" do
    @api.expects(:send_message).once.raises(Faraday::TimeoutError)
    job = NotificationJob.new(*arguments)
    job.executions = 2

    assert_no_enqueued_jobs do
      assert_raises(Faraday::TimeoutError) { job.perform_now }
    end
  end
end
