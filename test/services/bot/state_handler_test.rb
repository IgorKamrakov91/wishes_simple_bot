require "test_helper"
require "mocha/minitest"
require "telegram/bot"

class BotStateHandlerTest < ActiveSupport::TestCase
  setup do
    @user = User.create!(telegram_id: 30001, first_name: "State")
  end

  def context_for(text)
    mock("BotContext").tap do |context|
      context.stubs(:user).returns(@user)
      context.stubs(:text).returns(text)
      context.stubs(:bot).returns(nil)
      context.stubs(:chat_id).returns(@user.telegram_id)
    end
  end

  test "creating list state creates wishlist and clears state" do
    @user.start_creating_list!
    context = context_for("Travel gifts")
    context.expects(:send_text).with(
      I18n.t("bot.messages.list_created", title: "Travel gifts"),
      kind_of(Telegram::Bot::Types::InlineKeyboardMarkup)
    )

    Bot::StateHandler.new(context).handle

    assert_equal [ "Travel gifts" ], @user.wishlists.pluck(:title)
    assert_nil @user.reload.bot_state
    assert_nil @user.bot_payload
  end

  test "adding item url state treats dash as skipped url" do
    wishlist = Wishlist.create!(user: @user, title: "Birthday")
    item = wishlist.items.create!(title: "Puzzle")
    @user.update!(bot_state: "adding_item_url", bot_payload: { "item_id" => item.id, "wishlist_id" => wishlist.id })
    context = context_for("-")
    context.expects(:send_text).with(
      I18n.t("bot.messages.item_added"),
      kind_of(Telegram::Bot::Types::InlineKeyboardMarkup)
    )

    Bot::StateHandler.new(context).handle

    assert_nil item.reload.url
    assert_nil @user.reload.bot_state
    assert_nil @user.bot_payload
  end

  test "adding item url state trims surrounding whitespace" do
    wishlist = Wishlist.create!(user: @user, title: "Birthday")
    item = wishlist.items.create!(title: "Puzzle")
    @user.update!(bot_state: "adding_item_url", bot_payload: { "item_id" => item.id, "wishlist_id" => wishlist.id })
    context = context_for("  https://example.com/gift  ")
    context.expects(:send_text).with(
      I18n.t("bot.messages.item_added"),
      kind_of(Telegram::Bot::Types::InlineKeyboardMarkup)
    )

    Bot::StateHandler.new(context).handle

    assert_equal "https://example.com/gift", item.reload.url
  end

  test "editing item price normalizes commas without truncating cents" do
    wishlist = Wishlist.create!(user: @user, title: "Birthday")
    item = wishlist.items.create!(title: "Puzzle")
    @user.update!(bot_state: "editing_item", bot_payload: { "item_id" => item.id, "field" => "price" })
    context = context_for("12,50")
    context.expects(:send_text).with(
      I18n.t("bot.messages.field_updated", field: "price"),
      kind_of(Telegram::Bot::Types::InlineKeyboardMarkup)
    )

    Bot::StateHandler.new(context).handle

    assert_equal 12.50.to_d, item.reload.price
    assert_nil @user.reload.bot_state
    assert_nil @user.bot_payload
  end

  test "editing optional item fields treats dash as clearing the value" do
    wishlist = Wishlist.create!(user: @user, title: "Birthday")
    item = wishlist.items.create!(title: "Puzzle", url: "https://example.com")
    @user.update!(bot_state: "editing_item", bot_payload: { "item_id" => item.id, "field" => "url" })
    context = context_for("-")
    context.expects(:send_text).with(
      I18n.t("bot.messages.field_updated", field: "url"),
      kind_of(Telegram::Bot::Types::InlineKeyboardMarkup)
    )

    Bot::StateHandler.new(context).handle

    assert_nil item.reload.url
  end

  test "editing optional item fields treats blank text as clearing the value" do
    wishlist = Wishlist.create!(user: @user, title: "Birthday")
    item = wishlist.items.create!(title: "Puzzle", description: "Old text")
    @user.update!(bot_state: "editing_item", bot_payload: { "item_id" => item.id, "field" => "description" })
    context = context_for("   ")
    context.expects(:send_text).with(
      I18n.t("bot.messages.field_updated", field: "description"),
      kind_of(Telegram::Bot::Types::InlineKeyboardMarkup)
    )

    Bot::StateHandler.new(context).handle

    assert_nil item.reload.description
  end
end
