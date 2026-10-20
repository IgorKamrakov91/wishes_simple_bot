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

  test "edit prompts reject internal and unknown fields without changing state" do
    @owner.start_creating_list!
    context = context_for(@owner)
    fields = [ "wishlist_id", "reserved_by", "id", "created_at", "unknown", nil ]
    context.expects(:send_text).with(I18n.t("bot.messages.error")).times(fields.size)
    handler = Bot::Callbacks::ItemHandler.new(context)

    fields.each do |field|
      handler.edit_item_field_prompt(field, @item.id)
      assert_equal "creating_list", @owner.reload.bot_state
      assert_equal({}, @owner.bot_payload)
    end
  end

  test "stored edit states cannot update internal or unknown fields" do
    other_list = @viewer.wishlists.create!(title: "Other list")
    original_attributes = @item.attributes
    fields = [ "wishlist_id", "reserved_by", "id", "created_at", "unknown", nil ]
    context = context_for(@owner, other_list.id.to_s)
    context.expects(:send_text).with(I18n.t("bot.messages.error")).times(fields.size)

    fields.each do |field|
      @owner.update!(bot_state: "editing_item", bot_payload: { "item_id" => @item.id, "field" => field })
      Bot::StateHandler.new(context).handle
      assert_equal original_attributes, @item.reload.attributes
    end
  end

  test "all visible edit fields can be selected by the owner" do
    context = context_for(@owner)
    handler = Bot::Callbacks::ItemHandler.new(context)

    %w[title description url price].each do |field|
      context.expects(:send_text).with(I18n.t("bot.messages.enter_new_value", field: field))
      handler.edit_item_field_prompt(field, @item.id)
      assert_equal field, @owner.reload.bot_payload["field"]
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
