require "test_helper"
require "mocha/minitest"

class BotCallbacksTest < ActiveSupport::TestCase
  fixtures :users

  setup do
    @bot = mock("TelegramBot")
    @user = users(:one)
    @api_mock = mock("TelegramApi")
    @bot.stubs(:api).returns(@api_mock)
    @api_mock.stubs(:answer_callback_query)

    User.stubs(:find_or_create_from_telegram).returns(@user)
  end

  def build_callback(data, inline_message_id: nil)
    from_mock = mock("TelegramFrom")
    from_mock.stubs(:id).returns(@user.id)
    from_mock.stubs(:first_name).returns(@user.first_name)
    from_mock.stubs(:last_name).returns(@user.last_name)
    from_mock.stubs(:username).returns(@user.username)
    from_mock.stubs(:to_h).returns({ id: @user.id, first_name: @user.first_name, last_name: @user.last_name, username: @user.username })

    callback = mock("TelegramCallback")
    callback.stubs(:from).returns(from_mock)
    callback.stubs(:id).returns("some_callback_id")
    callback.stubs(:inline_message_id).returns(inline_message_id)
    callback.stubs(:data).returns(data)
    callback
  end

  test "inline shared list callback opens the share link" do
    previous_username = ENV["BOT_USERNAME"]
    ENV["BOT_USERNAME"] = "WishBot"
    wishlist = Wishlist.create!(user: @user, title: "Birthday")
    @api_mock.expects(:answer_callback_query).with(
      callback_query_id: "some_callback_id",
      url: "https://t.me/WishBot?start=l_#{wishlist.share_token}"
    )

    Bot::Callbacks::WishlistHandler.expects(:new).never

    Bot::Callbacks.handle(@bot, build_callback("open_shared_list:#{wishlist.id}", inline_message_id: "inline-1"))
  ensure
    ENV["BOT_USERNAME"] = previous_username
  end

  test "an inline callback with someone else's list id reveals no link and lets nobody in" do
    owner = User.create!(telegram_id: 51001, first_name: "Owner")
    wishlist = owner.wishlists.create!(title: "Private")
    @api_mock.expects(:answer_callback_query).with do |params|
      params[:url].nil? && params[:text] == I18n.t("bot.commands.link_outdated") &&
        params.values.none? { |value| value.to_s.include?(wishlist.share_token) }
    end

    Bot::Callbacks.handle(@bot, build_callback("open_shared_list:#{wishlist.id}", inline_message_id: "inline-1"))

    refute wishlist.has_viewer?(@user)
  end

  test "handle routes to WishlistHandler for show_lists" do
    Bot::Context.any_instance.stubs(:callback_data).returns("show_lists")
    Bot::Context.any_instance.stubs(:send_text)

    wishlist_handler_mock = mock("WishlistHandler")
    Bot::Callbacks::WishlistHandler.expects(:new).with(instance_of(Bot::Context)).returns(wishlist_handler_mock)
    wishlist_handler_mock.expects(:show_lists)

    Bot::Callbacks.handle(@bot, build_callback("show_lists"))
  end

  test "handle routes to ItemHandler for add_item" do
    Bot::Context.any_instance.stubs(:callback_data).returns("add_item:123")
    Bot::Context.any_instance.stubs(:send_text)

    item_handler_mock = mock("ItemHandler")
    Bot::Callbacks::ItemHandler.expects(:new).with(instance_of(Bot::Context)).returns(item_handler_mock)
    item_handler_mock.expects(:add_item_prompt).with(123)

    Bot::Callbacks.handle(@bot, build_callback("add_item:123"))
  end

  test "handle ignores unknown routes" do
    Bot::Context.any_instance.expects(:send_text).never
    Bot::Callbacks::WishlistHandler.expects(:new).never
    Bot::Callbacks::ItemHandler.expects(:new).never

    Bot::Callbacks.handle(@bot, build_callback("unknown_route"))
  end

  test "handle rescues from RecordNotFound" do
    Bot::Context.any_instance.stubs(:callback_data).returns("show_lists")
    Bot::Callbacks::WishlistHandler.stubs(:new).raises(ActiveRecord::RecordNotFound)
    Bot::Context.any_instance.expects(:send_text).with("Произошла ошибка. Попробуйте еще раз.")

    Bot::Callbacks.handle(@bot, build_callback("show_lists"))
  end

  test "handle rescues from StandardError" do
    Bot::Context.any_instance.stubs(:callback_data).returns("show_lists")
    Bot::Callbacks::WishlistHandler.stubs(:new).raises(StandardError)
    Bot::Context.any_instance.expects(:send_text).with("Произошла ошибка. Попробуйте еще раз.")

    Bot::Callbacks.handle(@bot, build_callback("show_lists"))
  end
end
