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
