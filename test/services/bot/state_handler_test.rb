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
end
