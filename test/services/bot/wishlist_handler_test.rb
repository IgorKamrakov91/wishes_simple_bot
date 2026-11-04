require "test_helper"
require "mocha/minitest"
require "telegram/bot"

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

  def capture_render(context)
    rendered = {}
    context.stubs(:render).with do |text, keyboard, *|
      rendered[:text] = text
      rendered[:keyboard] = keyboard
      true
    end
    rendered
  end

  test "show_lists puts each list only in its button" do
    wishlist = Wishlist.create!(user: @user, title: "Holidays")
    Item.create!(wishlist: wishlist, title: "Gift", reserved_by: 1)
    Item.create!(wishlist: wishlist, title: "Another gift")

    context = build_context
    rendered = capture_render(context)
    Bot::Callbacks::WishlistHandler.new(context).show_lists

    refute_includes rendered[:text], "Holidays"
    assert_includes rendered[:text], "Страница 1 из 1"

    row = rendered[:keyboard].inline_keyboard.first
    assert_equal "Holidays · 2 подарка", row.first.text
    assert_equal "open_list:#{wishlist.id}", row.first.callback_data
  end

  test "open_list shows the share link as a copy button" do
    wishlist = Wishlist.create!(user: @user, title: "Holidays")

    context = build_context
    rendered = capture_render(context)
    Bot::Callbacks::WishlistHandler.new(context).open_list(wishlist.id)

    share_btn = rendered[:keyboard].inline_keyboard.flatten.find(&:copy_text)
    assert_equal I18n.t("bot.buttons.share"), share_btn.text
    assert_equal "https://t.me/TestBot?start=l_#{wishlist.share_token}", share_btn.copy_text.text
    assert_nil share_btn.switch_inline_query
  end

  test "open_list refuses a list the user was never let into" do
    owner = User.create!(telegram_id: 20002, first_name: "Owner")
    wishlist = Wishlist.create!(user: owner, title: "Birthday")

    context = build_context
    context.expects(:render).never

    assert_raises(ActiveRecord::RecordNotFound) do
      Bot::Callbacks::WishlistHandler.new(context).open_list(wishlist.id)
    end
    refute wishlist.has_viewer?(@user)
  end

  test "open_list shows a list the guest was let into" do
    owner = User.create!(telegram_id: 20002, first_name: "Owner")
    wishlist = Wishlist.create!(user: owner, title: "Birthday")
    wishlist.admit!(@user)

    context = build_context
    rendered = capture_render(context)
    Bot::Callbacks::WishlistHandler.new(context).open_list(wishlist.id)

    assert_match "Birthday", rendered[:text]
  end

  test "delete_list asks for confirmation first" do
    wishlist = Wishlist.create!(user: @user, title: "Holidays")

    context = build_context
    rendered = capture_render(context)
    Bot::Callbacks::WishlistHandler.new(context).confirm_delete_list(wishlist.id)

    assert Wishlist.exists?(wishlist.id)
    assert_equal "delete_list:#{wishlist.id}", rendered[:keyboard].inline_keyboard.first.first.callback_data
  end

  test "delete_list removes the list and shows a toast" do
    wishlist = Wishlist.create!(user: @user, title: "Holidays")

    context = build_context
    capture_render(context)
    Bot::Callbacks::WishlistHandler.new(context).delete_list(wishlist.id)

    refute Wishlist.exists?(wishlist.id)
    assert_equal I18n.t("bot.messages.list_deleted"), context.notice
  end

  test "guests cannot delete someone else's list" do
    owner = User.create!(telegram_id: 20002, first_name: "Owner")
    wishlist = Wishlist.create!(user: owner, title: "Birthday")

    assert_raises(ActiveRecord::RecordNotFound) do
      Bot::Callbacks::WishlistHandler.new(build_context).delete_list(wishlist.id)
    end
  end

  test "open_list escapes html-sensitive list title in header" do
    wishlist = Wishlist.create!(user: @user, title: "Party <script> & Friends")
    context = build_context
    rendered = capture_render(context)

    Bot::Callbacks::WishlistHandler.new(context).open_list(wishlist.id)
    header_text = rendered[:text]

    assert_includes header_text, "Party &lt;script&gt; &amp; Friends"
    refute_includes header_text, "Party <script> & Friends"
  end
end
