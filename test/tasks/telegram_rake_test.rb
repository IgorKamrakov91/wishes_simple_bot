require "test_helper"
require "open3"

class TelegramRakeTest < ActiveSupport::TestCase
  # A fresh process, as in production: nothing else has loaded the gem yet
  test "set_webhook loads the Telegram client on its own" do
    script = "Rails.application.load_tasks; print defined?(Telegram::Bot::Client).inspect"
    output, status = Open3.capture2e({ "RAILS_ENV" => "test" }, "bin/rails", "runner", script, chdir: Rails.root.to_s)

    assert status.success?, output
    assert_equal '"constant"', output.lines.last
  end
end
