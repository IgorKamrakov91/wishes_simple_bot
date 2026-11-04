require "test_helper"
require "mocha/minitest"
require "telegram/bot"

# Guests get into a list only through its share link
class BotListAccessTest < ActiveSupport::TestCase
  setup do
    @owner = User.create!(telegram_id: 41001, first_name: "Owner")
    @guest = User.create!(telegram_id: 41002, first_name: "Guest")
    @stranger = User.create!(telegram_id: 41003, first_name: "Stranger")
    @wishlist = @owner.wishlists.create!(title: "Birthday")
    @item = @wishlist.items.create!(title: "Puzzle")
    @wishlist.admit!(@guest)
  end

  def context_for(user, text: nil)
    from = Telegram::Bot::Types::User.new(id: user.telegram_id, is_bot: false, first_name: user.first_name)
    chat = Telegram::Bot::Types::Chat.new(id: user.telegram_id, type: "private")
    message = Telegram::Bot::Types::Message.new(**{ message_id: 1, date: 0, chat: chat, from: from, text: text }.compact)
    Bot::Context.new(bot: mock("TelegramBot"), user: user, source: message)
  end

  def start(user, payload)
    context = context_for(user, text: "/start #{payload}")
    Bot::Context.stubs(:new).returns(context)
    User.stubs(:find_or_create_from_telegram).returns(user)
    yield context
    Bot::Commands.handle(context.bot, context.source)
  end

  test "share tokens are random and unique" do
    other = @owner.wishlists.create!(title: "New year")

    assert_equal 24, @wishlist.share_token.length
    refute_equal @wishlist.share_token, other.share_token
  end

  test "accessible_to covers owned and admitted lists only" do
    assert_includes Wishlist.accessible_to(@owner), @wishlist
    assert_includes Wishlist.accessible_to(@guest), @wishlist
    refute_includes Wishlist.accessible_to(@stranger), @wishlist
    refute_includes Item.accessible_to(@stranger), @item
  end

  test "admit! never adds the owner as a viewer and is idempotent" do
    @wishlist.admit!(@owner)
    2.times { @wishlist.admit!(@guest) }

    refute @wishlist.has_viewer?(@owner)
    assert_equal 1, @wishlist.list_viewers.where(user: @guest).count
  end

  test "a share link lets a new guest in" do
    start(@stranger, "l_#{@wishlist.share_token}") do |context|
      context.expects(:render).with { |text, *| text.include?("Birthday") }
    end

    assert @wishlist.has_viewer?(@stranger)
  end

  test "an unknown token lets nobody in" do
    start(@stranger, "l_wrongtoken") do |context|
      context.expects(:send_text).with(I18n.t("bot.commands.list_not_found"))
    end

    refute @wishlist.has_viewer?(@stranger)
  end

  test "an old id link no longer lets strangers in" do
    start(@stranger, "list_#{@wishlist.id}") do |context|
      context.expects(:send_text).with(I18n.t("bot.commands.link_outdated"))
      context.expects(:render).never
    end

    refute @wishlist.has_viewer?(@stranger)
  end

  test "an old id link still opens the list for an existing guest" do
    start(@guest, "list_#{@wishlist.id}") do |context|
      context.expects(:render).with { |text, *| text.include?("Birthday") }
    end
  end

  test "strangers can neither open nor reserve items" do
    handler = Bot::Callbacks::ItemHandler.new(context_for(@stranger))

    assert_raises(ActiveRecord::RecordNotFound) { handler.show_item(@item.id) }
    assert_raises(ActiveRecord::RecordNotFound) { handler.toggle_reserve(@item.id) }
    assert_nil @item.reload.reserved_by
  end

  test "strangers cannot page through a list" do
    handler = Bot::Callbacks::WishlistHandler.new(context_for(@stranger))

    assert_raises(ActiveRecord::RecordNotFound) { handler.open_list(@wishlist.id, 1) }
    assert_raises(ActiveRecord::RecordNotFound) { handler.open_shared_list(@wishlist.id) }
  end
end
