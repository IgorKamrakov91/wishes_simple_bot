require "test_helper"
require "mocha/minitest"
require "telegram/bot"

class TelegramMessageRecoveryTest < ActionDispatch::IntegrationTest
  setup do
    @previous_token = ENV["TELEGRAM_BOT_TOKEN"]
    @previous_secret = ENV["TELEGRAM_WEBHOOK_SECRET"]
    ENV["TELEGRAM_BOT_TOKEN"] = "123:test-token"
    ENV["TELEGRAM_WEBHOOK_SECRET"] = "message-recovery-test"
    @user = User.create!(telegram_id: 99101, first_name: "Recovery")
    @wishlist = @user.wishlists.create!(title: "Birthday")
    @sent = []
    @api = mock("TelegramApi")
    @api.stubs(:send_message).with { |params| @sent << params; true }
    Telegram::Bot::Client.stubs(:run).yields(stub(api: @api))
  end

  teardown do
    ENV["TELEGRAM_BOT_TOKEN"] = @previous_token
    ENV["TELEGRAM_WEBHOOK_SECRET"] = @previous_secret
  end

  test "an unexpected input error replies and acknowledges the update without losing the draft" do
    @user.update!(bot_state: "adding_item_url", bot_payload: {
      "wishlist_id" => @wishlist.id, "title" => "Puzzle", "draft_id" => "drecovery"
    })
    before = @user.attributes.slice("bot_state", "bot_payload")
    Bot::StateHandler.any_instance.expects(:handle).raises(StandardError, "private input error")

    post_message("https://shop.example/puzzle")

    assert_response :ok
    assert_equal before, @user.reload.attributes.slice("bot_state", "bot_payload")
    assert_includes @sent.last[:text], I18n.t("bot.commands.message_failed")
    assert_equal %w[show_lists show_reservations main_menu help], callbacks
    assert_empty @wishlist.items
  end

  test "an unexpected command error has recovery navigation" do
    Bot::Callbacks::WishlistHandler.any_instance.expects(:show_lists).raises(StandardError, "private command error")

    post_message("/my")

    assert_response :ok
    assert_includes @sent.last[:text], I18n.t("bot.commands.message_failed")
    assert_includes callbacks, "help"
  end

  test "recovery still replies when loading the user fails" do
    User.expects(:find_or_create_from_telegram).raises(ActiveRecord::ConnectionNotEstablished, "private database error")

    post_message("/start")

    assert_response :ok
    assert_includes @sent.last[:text], I18n.t("bot.commands.message_failed")
    assert_equal %w[show_lists show_reservations main_menu help], callbacks
  end

  test "a delivery error after creating a list does not claim that nothing was saved" do
    @user.start_creating_list!
    @api.expects(:send_message).with { |params| params[:text].include?("New list") }
      .raises(Faraday::TimeoutError, "private delivery error")

    assert_difference("Wishlist.count", 1) { post_message("New list") }

    assert_response :ok
    assert_equal [ "Birthday", "New list" ], @user.wishlists.order(:id).pluck(:title)
    assert_equal "adding_item", @user.reload.bot_state
    assert_includes @sent.last[:text], I18n.t("bot.commands.message_failed")
    refute_includes @sent.last[:text], "ничего не сохранено"
    assert_includes callbacks, "show_lists"
  end

  test "a failed fallback is acknowledged and neither exception leaks private contents" do
    output = StringIO.new
    previous_logger = Rails.logger
    Rails.logger = ActiveSupport::Logger.new(output)
    @user.start_creating_list!
    before = @user.attributes.slice("bot_state", "bot_payload")
    Bot::Callbacks::HelpHandler.any_instance.expects(:show_help)
      .raises(StandardError, "PRIVATE_HANDLER_TEXT https://t.me/Bot?start=l_PRIVATE_TOKEN")
    @api.expects(:send_message).raises(Faraday::TimeoutError, "PRIVATE_FALLBACK_TEXT")

    post_message("/help")

    assert_response :ok
    assert_equal before, @user.reload.attributes.slice("bot_state", "bot_payload")
    assert_includes output.string, "StandardError"
    assert_includes output.string, "Faraday::TimeoutError"
    %w[PRIVATE_HANDLER_TEXT PRIVATE_TOKEN PRIVATE_FALLBACK_TEXT].each do |secret|
      refute_includes output.string, secret
    end
  ensure
    Rails.logger = previous_logger
  end

  test "normal validation errors keep their specific feedback and input" do
    @user.start_creating_list!

    assert_no_difference("Wishlist.count") { post_message("x" * (Wishlist::TITLE_LIMIT + 1)) }

    assert_response :ok
    assert_includes @sent.last[:text], I18n.t("bot.input_errors.title.too_long", count: Wishlist::TITLE_LIMIT)
    refute_includes @sent.last[:text], I18n.t("bot.commands.message_failed")
    assert_equal "creating_list", @user.reload.bot_state
  end

  test "unknown invitation tokens explain recovery without granting access" do
    post_message("/start l_missingtoken")

    assert_response :ok
    assert_includes @sent.last[:text], I18n.t("bot.commands.invitation_unavailable")
    assert_equal %w[main_menu help], callbacks
    refute_includes @sent.last[:text], "missingtoken"
    assert_empty @user.viewed_wishlists
  end

  test "legacy invitations give strangers the same recovery without granting access" do
    owner = User.create!(telegram_id: 99102, first_name: "Owner")
    private_list = owner.wishlists.create!(title: "Private list")

    post_message("/start list_#{private_list.id}")

    assert_response :ok
    assert_includes @sent.last[:text], I18n.t("bot.commands.invitation_unavailable")
    assert_equal %w[main_menu help], callbacks
    refute_includes @sent.last[:text], private_list.title
    refute private_list.has_viewer?(@user)
  end

  private

  def callbacks
    @sent.last[:reply_markup].inline_keyboard.flatten.map(&:callback_data)
  end

  def post_message(text)
    post "/telegram/webhook", params: {
      update_id: 99301,
      message: {
        message_id: 1, date: 1, text: text,
        from: { id: @user.telegram_id, is_bot: false, first_name: "Recovery" },
        chat: { id: @user.telegram_id, type: "private" }
      }
    }, as: :json, headers: { Bot::Webhook::SECRET_HEADER => Bot::Webhook.secret }
  end
end
