require "test_helper"
require "mocha/minitest"
require "telegram/bot"

class BotStateHandlerTest < ActiveSupport::TestCase
  setup do
    @user = User.create!(telegram_id: 30001, first_name: "State")
  end

  def context_for(text)
    Bot::Context.new(bot: nil, user: @user, source: nil).tap do |context|
      context.stubs(:text).returns(text)
      context.stubs(:chat_id).returns(@user.telegram_id)
    end
  end

  test "creating list state creates wishlist and prompts for its first gift" do
    @user.start_creating_list!
    context = context_for("Travel gifts")
    context.expects(:render).with(regexp_matches(/Travel gifts/), anything)

    Bot::StateHandler.new(context).handle

    assert_equal [ "Travel gifts" ], @user.wishlists.pluck(:title)
    assert_equal "adding_item", @user.reload.bot_state
    assert @user.bot_payload["first_item"]
  end

  test "blank list title reports an error and allows retry" do
    @user.start_creating_list!
    context = context_for("   ")
    context.expects(:send_text).with(I18n.t("bot.input_errors.title.blank"), anything)

    assert_no_difference("Wishlist.count") do
      Bot::StateHandler.new(context).handle
    end
    assert_equal "creating_list", @user.reload.bot_state

    retry_context = context_for("Travel gifts")
    retry_context.expects(:render).with(regexp_matches(/Travel gifts/), anything)
    Bot::StateHandler.new(retry_context).handle

    assert_equal [ "Travel gifts" ], @user.wishlists.pluck(:title)
    assert_equal "adding_item", @user.reload.bot_state
  end

  test "blank renamed list title preserves the original title and state" do
    wishlist = @user.wishlists.create!(title: "Birthday")
    @user.start_renaming_list!(wishlist_id: wishlist.id)
    payload = @user.bot_payload
    context = context_for("   ")
    context.expects(:send_text).with(I18n.t("bot.input_errors.title.blank"), anything)

    Bot::StateHandler.new(context).handle

    assert_equal "Birthday", wishlist.reload.title
    assert_equal "renaming_list", @user.reload.bot_state
    assert_equal payload, @user.bot_payload
  end

  test "blank new item title asks for the name again" do
    wishlist = @user.wishlists.create!(title: "Birthday")
    payload = { "wishlist_id" => wishlist.id }
    @user.update!(bot_state: "adding_item", bot_payload: payload)
    context = context_for("   ")
    context.expects(:send_text).with(I18n.t("bot.input_errors.title.blank"), anything)

    assert_no_difference("Item.count") do
      Bot::StateHandler.new(context).handle
    end

    assert_equal "adding_item", @user.reload.bot_state
    assert_equal payload, @user.bot_payload
  end

  test "invalid edited price preserves its value and allows retry" do
    wishlist = @user.wishlists.create!(title: "Birthday")
    item = wishlist.items.create!(title: "Puzzle", price: 10)
    payload = { "item_id" => item.id, "field" => "price" }
    @user.update!(bot_state: "editing_item", bot_payload: payload)

    {
      "not a price" => "bot.input_errors.price.not_a_number",
      "0" => "bot.input_errors.price.greater_than",
      "-5" => "bot.input_errors.price.greater_than"
    }.each do |value, message|
      context = context_for(value)
      context.expects(:send_text).with(I18n.t(message), anything)

      Bot::StateHandler.new(context).handle

      assert_equal 10.to_d, item.reload.price
      assert_equal "editing_item", @user.reload.bot_state
      assert_equal payload, @user.bot_payload
    end

    context = context_for("12,50")
    Bot::Callbacks::ItemHandler.any_instance.expects(:show_item).with(item.id)
    Bot::StateHandler.new(context).handle

    assert_equal 12.50.to_d, item.reload.price
    assert_nil @user.reload.bot_state
    assert_nil @user.bot_payload
  end

  test "an edit delivered twice only updates the gift once" do
    wishlist = @user.wishlists.create!(title: "Birthday")
    item = wishlist.items.create!(title: "Puzzle", price: 10)
    @user.update!(bot_state: "editing_item", bot_payload: { "item_id" => item.id, "field" => "price" })
    stale_user = User.find(@user.id)
    context = context_for("12,50")
    context.stubs(:user).returns(stale_user)
    Bot::Callbacks::ItemHandler.any_instance.expects(:show_item).with(item.id).once

    Bot::StateHandler.new(context_for("12,50")).handle
    item.update!(price: 20)
    Bot::StateHandler.new(context).handle

    assert_equal 20.to_d, item.reload.price
    assert_nil stale_user.reload.bot_state
  end

  test "a cancelled edit cannot be applied by a stale delivery" do
    wishlist = @user.wishlists.create!(title: "Birthday")
    item = wishlist.items.create!(title: "Puzzle", price: 10)
    @user.update!(bot_state: "editing_item", bot_payload: { "item_id" => item.id, "field" => "price" })
    stale_user = User.find(@user.id)
    context = context_for("12,50")
    context.stubs(:user).returns(stale_user)
    Bot::Callbacks::ItemHandler.any_instance.expects(:show_item).never
    @user.clear_state!

    Bot::StateHandler.new(context).handle

    assert_equal 10.to_d, item.reload.price
    assert_nil stale_user.reload.bot_state
  end

  test "a stale edit does not consume a newly started list prompt" do
    wishlist = @user.wishlists.create!(title: "Birthday")
    item = wishlist.items.create!(title: "Puzzle")
    @user.update!(bot_state: "editing_item", bot_payload: { "item_id" => item.id, "field" => "title" })
    stale_user = User.find(@user.id)
    context = context_for("New name")
    context.stubs(:user).returns(stale_user)
    Bot::Callbacks::ItemHandler.any_instance.expects(:show_item).never
    @user.start_creating_list!

    Bot::StateHandler.new(context).handle

    assert_equal "Puzzle", item.reload.title
    assert_equal "creating_list", @user.reload.bot_state
  end

  test "adding item url state treats dash as skipped url" do
    wishlist = Wishlist.create!(user: @user, title: "Birthday")
    item = wishlist.items.create!(title: "Puzzle")
    @user.update!(bot_state: "adding_item_url", bot_payload: { "item_id" => item.id, "wishlist_id" => wishlist.id })
    context = context_for("-")
    context.expects(:render).with(
      I18n.t("bot.messages.item_added", title: "Puzzle", list: "Birthday"),
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
    context.expects(:render).with(
      I18n.t("bot.messages.item_added", title: "Puzzle", list: "Birthday"),
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
    Bot::Callbacks::ItemHandler.any_instance.expects(:show_item).with(item.id)

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
    Bot::Callbacks::ItemHandler.any_instance.expects(:show_item).with(item.id)

    Bot::StateHandler.new(context).handle

    assert_nil item.reload.url
  end

  test "editing optional item fields treats blank text as clearing the value" do
    wishlist = Wishlist.create!(user: @user, title: "Birthday")
    item = wishlist.items.create!(title: "Puzzle", description: "Old text")
    @user.update!(bot_state: "editing_item", bot_payload: { "item_id" => item.id, "field" => "description" })
    context = context_for("   ")
    Bot::Callbacks::ItemHandler.any_instance.expects(:show_item).with(item.id)

    Bot::StateHandler.new(context).handle

    assert_nil item.reload.description
  end
end
