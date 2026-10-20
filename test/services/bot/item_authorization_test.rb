require "test_helper"
require "mocha/minitest"
require "telegram/bot"

class BotItemAuthorizationTest < ActiveSupport::TestCase
  setup do
    @owner = User.create!(telegram_id: 31001, first_name: "Owner")
    @viewer = User.create!(telegram_id: 31002, first_name: "Viewer")
    @wishlist = @owner.wishlists.create!(title: "Birthday")
    @wishlist.list_viewers.create!(user: @viewer)
    @item = @wishlist.items.create!(title: "Puzzle", url: "https://example.com")
  end

  def context_for(user, text = "Changed")
    mock("BotContext").tap do |context|
      context.stubs(:user).returns(user)
      context.stubs(:text).returns(text)
      context.stubs(:bot).returns(nil)
      context.stubs(:chat_id).returns(user.telegram_id)
    end
  end

  test "shared list viewers cannot invoke owner item callbacks" do
    handler = Bot::Callbacks::ItemHandler.new(context_for(@viewer))

    [ [ :add_item_prompt, @wishlist.id ], [ :edit_item_menu, @item.id ],
      [ :edit_item_field_prompt, "title", @item.id ], [ :delete_item, @item.id ] ].each do |method, *args|
      assert_raises(ActiveRecord::RecordNotFound) { handler.public_send(method, *args) }
    end

    assert_nil @viewer.reload.bot_state
    assert_equal "Puzzle", @item.reload.title
  end

  test "owners can start adding and editing items" do
    context = context_for(@owner)
    context.expects(:send_text).with(I18n.t("bot.messages.enter_item_name"))
    context.expects(:send_text).with(I18n.t("bot.messages.enter_new_value", field: "title"))
    handler = Bot::Callbacks::ItemHandler.new(context)

    handler.add_item_prompt(@wishlist.id)
    assert_equal "adding_item", @owner.reload.bot_state
    handler.edit_item_field_prompt("title", @item.id)
    assert_equal "editing_item", @owner.reload.bot_state
    assert_equal @item.id, @owner.bot_payload["item_id"]
  end

  test "owners can delete their items" do
    context = context_for(@owner)
    context.stubs(:inline_btn).returns(:button)
    context.stubs(:build_keyboard).returns(:keyboard)
    context.expects(:send_text).with(I18n.t("bot.messages.item_deleted_success"), :keyboard)

    assert_difference("Item.count", -1) do
      Bot::Callbacks::ItemHandler.new(context).delete_item(@item.id)
    end
  end

  test "stored item states cannot mutate a shared list owner's item" do
    [ [ "adding_item_url", {} ], [ "editing_item", { "field" => "title" } ] ].each do |state, payload|
      @viewer.update!(bot_state: state, bot_payload: payload.merge("item_id" => @item.id, "wishlist_id" => @wishlist.id))

      assert_raises(ActiveRecord::RecordNotFound) do
        Bot::StateHandler.new(context_for(@viewer)).handle
      end
      assert_equal "Puzzle", @item.reload.title
      assert_equal "https://example.com", @item.url
    end
  end

  test "ownership is rechecked if an item moves after editing starts" do
    @owner.update!(bot_state: "editing_item", bot_payload: { "item_id" => @item.id, "field" => "title" })
    other_list = @viewer.wishlists.create!(title: "Other list")
    @item.update!(wishlist: other_list)

    assert_raises(ActiveRecord::RecordNotFound) do
      Bot::StateHandler.new(context_for(@owner)).handle
    end
    assert_equal "Puzzle", @item.reload.title
  end
end
