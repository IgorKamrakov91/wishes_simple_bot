require "test_helper"
require "mocha/minitest"
require "telegram/bot"

# Logs keep what happened, not what people wrote or who they are
class BotQuietLogsTest < ActiveSupport::TestCase
  test "Telegram texts, names and invitations are filtered from request params" do
    filter = ActiveSupport::ParameterFilter.new(Rails.application.config.filter_parameters)
    params = {
      "update_id" => 1,
      "message" => {
        "text" => "/start l_SecretToken123",
        "chat" => { "id" => 42, "type" => "private", "title" => "Семья" },
        "from" => { "id" => 42, "first_name" => "Анна", "last_name" => "К", "username" => "anna" }
      },
      "callback_query" => { "data" => "open_list:7" },
      "inline_query" => { "query" => "день рождения" }
    }

    filtered = filter.filter(params)
    serialized = filtered.to_s

    %w[SecretToken123 Анна anna Семья день].each { |secret| refute_includes serialized, secret }
    assert_equal 42, filtered.dig("message", "from", "id")
    assert_equal "private", filtered.dig("message", "chat", "type")
    assert_equal "open_list:7", filtered.dig("callback_query", "data")
  end

  test "sending a message doesn't log its text" do
    output = StringIO.new
    previous = Rails.logger
    Rails.logger = ActiveSupport::Logger.new(output)
    api = mock("TelegramApi")
    api.stubs(:send_message)
    helper = Object.new.extend(Bot::Helpers)

    helper.send_text(stub(api: api), 42, "Плед для Анны")

    refute_includes output.string, "Плед"
  ensure
    Rails.logger = previous
  end
end

class BotListCreationLockTest < ActiveSupport::TestCase
  setup do
    @user = User.create!(telegram_id: 96001, first_name: "Lock")
  end

  def handler_for(text)
    user = User.find(@user.id) # each delivery loads its own copy
    context = mock("BotContext")
    context.stubs(:user).returns(user)
    context.stubs(:text).returns(text)
    context.stubs(:non_text_message?).returns(false)
    context.stubs(:bot).returns(nil)
    context.stubs(:chat_id).returns(user.telegram_id)
    context.stubs(:try).with(:non_text_message?).returns(false)
    Bot::StateHandler.new(context)
  end

  test "the same answer delivered twice creates one list" do
    @user.start_creating_list!
    first = handler_for("ДР")
    second = handler_for("ДР")
    Bot::Callbacks::WishlistHandler.any_instance.expects(:open_list).once

    assert_difference("Wishlist.count", 1) do
      first.handle
      second.handle
    end
    assert_nil @user.reload.bot_state
  end

  test "a rename delivered after the input ended changes nothing" do
    wishlist = @user.wishlists.create!(title: "Старое")
    @user.start_renaming_list!(wishlist_id: wishlist.id)
    first = handler_for("Новое")
    late = handler_for("Ещё новее")
    Bot::Callbacks::WishlistHandler.any_instance.expects(:open_list).once

    first.handle
    late.handle

    assert_equal "Новое", wishlist.reload.title
  end
end

class BotLeakRegressionTest < ActiveSupport::TestCase
  FAKE_TOKEN = "123456789:FAKE_BOT_TOKEN_abcdefghijklmnopqrstu"

  setup do
    @previous_token = ENV["TELEGRAM_BOT_TOKEN"]
    ENV["TELEGRAM_BOT_TOKEN"] = FAKE_TOKEN
  end

  teardown do
    ENV["TELEGRAM_BOT_TOKEN"] = @previous_token
  end

  test "links inside messages and buttons are filtered from request params" do
    filter = ActiveSupport::ParameterFilter.new(Rails.application.config.filter_parameters)
    params = { "message" => {
      "entities" => [ { "type" => "text_link", "offset" => 0, "length" => 4, "url" => "https://t.me/WishBot?start=l_FAKE_INVITE_TOKEN" } ],
      "reply_markup" => { "inline_keyboard" => [ [ { "text" => "Открыть", "url" => "https://t.me/WishBot?start=l_FAKE_INVITE_TOKEN" } ] ] }
    } }

    refute_includes filter.filter(params).to_s, "FAKE_INVITE_TOKEN"
  end

  test "a non-JSON Telegram error doesn't carry the bot token" do
    env = stub(url: URI("https://api.telegram.org/bot#{FAKE_TOKEN}/sendMessage"))
    error = Telegram::Bot::Exceptions::ResponseError.new(response: stub(status: 502, body: "<html>Bad Gateway</html>", env: env))

    [ error.message, error.to_s, error.data.to_s, error.inspect, error.full_message ].each do |text|
      refute_includes text, "FAKE_BOT_TOKEN", text
    end
    assert_equal 502, error.error_code
  end

  test "a job that gives up after Telegram errors logs no token" do
    output = StringIO.new
    previous = Rails.logger
    Rails.logger = ActiveSupport::Logger.new(output)
    ActiveJob::Base.logger = Rails.logger
    user = User.create!(telegram_id: 97001, first_name: "Owner")
    env = stub(url: URI("https://api.telegram.org/bot#{FAKE_TOKEN}/sendMessage"))
    api = mock("TelegramApi")
    api.stubs(:send_message).raises(Telegram::Bot::Exceptions::ResponseError.new(response: stub(status: 502, body: "oops", env: env)))
    Telegram::Bot::Client.stubs(:new).returns(stub(api: api))
    job = NotificationJob.new(user.telegram_id, "own_reserved", { "title" => "Плед", "list" => "ДР" }, "ru")
    job.executions = 3

    assert_raises(Telegram::Bot::Exceptions::ResponseError) { job.perform_now }
    refute_includes output.string, "FAKE_BOT_TOKEN"
  ensure
    Rails.logger = previous
    ActiveJob::Base.logger = previous
  end
end
