require "test_helper"
require "mocha/minitest"

class BotWishlistHandlerTest < ActiveSupport::TestCase
  setup do
    # Ensure deterministic bot username for share link
    @prev_username = ENV["BOT_USERNAME"]
    ENV["BOT_USERNAME"] = "TestBot"

    @bot = mock("TelegramBot")
    @api = mock("TelegramApi")
    @bot.stubs(:api).returns(@api)

    @user = User.create!(telegram_id: 20001, first_name: "Tester", username: "tester")
  end

  teardown do
    ENV["BOT_USERNAME"] = @prev_username
  end

  def build_context
    # Minimal source that provides from.id for chat_id resolution
    from = mock("From")
    from.stubs(:id).returns(999)

    source = mock("CallbackSource")
    source.stubs(:message).returns(nil)
    source.stubs(:from).returns(from)

    Bot::Context.new(bot: @bot, user: @user, source: source)
  end

  test "show_lists builds share button with copy_text and updated label" do
    # Create single wishlist for the user
    wishlist = Wishlist.create!(user: @user, title: "Holidays")

    context = build_context

    captured_keyboard = nil
    # Intercept send_text to capture keyboard of the lists message
    context.stubs(:send_text).with do |text, keyboard, *rest|
      if text == I18n.t("bot.buttons.my_lists")
        captured_keyboard = keyboard
      end
      true
    end

    handler = Bot::Callbacks::WishlistHandler.new(context)
    handler.show_lists

    assert captured_keyboard, "Expected keyboard to be sent for my_lists"

    # Inline keyboard structure: rows of buttons
    rows = captured_keyboard.inline_keyboard
    assert rows.is_a?(Array), "inline_keyboard should be an Array"

    # Find the row for our wishlist title and its share button
    row = rows.find { |r| r[0].text == "Holidays" }
    refute_nil row, "Expected a row with the wishlist title button"

    share_btn = row[1]
    assert_equal I18n.t("bot.buttons.share"), share_btn.text, "Share button label should be updated"

    # Ensure copy_text is present and correctly formed, and switch_inline_query is not used
    expected_url = "https://t.me/TestBot?start=list_#{wishlist.id}"

    # `copy_text` may be stored as a Hash in the Telegram type
    copy_text = share_btn.respond_to?(:copy_text) ? share_btn.copy_text : nil
    assert copy_text, "Share button should include copy_text payload"
    assert_equal expected_url, copy_text["text"] || copy_text[:text]

    # There must be no switch_inline_query
    if share_btn.respond_to?(:switch_inline_query)
      assert_nil share_btn.switch_inline_query, "switch_inline_query should not be set"
    end
  end
end
