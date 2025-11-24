require 'test_helper'
require 'mocha/minitest'

class BotCallbacksTest < ActiveSupport::TestCase
  fixtures :users

  setup do
    @bot = mock('TelegramBot')
    @user = users(:one)
    @api_mock = mock('TelegramApi')
    @bot.stubs(:api).returns(@api_mock)
    @api_mock.stubs(:answer_callback_query)

    User.stubs(:find_or_create_from_telegram).returns(@user)
  end

  def build_callback(data)
    from_mock = mock('TelegramFrom')
    from_mock.stubs(:id).returns(@user.id)
    from_mock.stubs(:first_name).returns(@user.first_name)
    from_mock.stubs(:last_name).returns(@user.last_name)
    from_mock.stubs(:username).returns(@user.username)
    from_mock.stubs(:to_h).returns({ id: @user.id, first_name: @user.first_name, last_name: @user.last_name, username: @user.username })

    callback = mock('TelegramCallback')
    callback.stubs(:from).returns(from_mock)
    callback.stubs(:id).returns('some_callback_id')
    callback.stubs(:inline_message_id).returns(nil)
    callback.stubs(:data).returns(data)
    callback
  end

  test 'handle routes to WishlistHandler for show_lists' do
    Bot::Context.any_instance.stubs(:callback_data).returns('show_lists')
    Bot::Context.any_instance.stubs(:send_text)

    wishlist_handler_mock = mock('WishlistHandler')
    Bot::Callbacks::WishlistHandler.expects(:new).with(instance_of(Bot::Context)).returns(wishlist_handler_mock)
    wishlist_handler_mock.expects(:show_lists)

    Bot::Callbacks.handle(@bot, build_callback('show_lists'))
  end

  test 'handle routes to ItemHandler for add_item' do
    Bot::Context.any_instance.stubs(:callback_data).returns('add_item:123')
    Bot::Context.any_instance.stubs(:send_text)

    item_handler_mock = mock('ItemHandler')
    Bot::Callbacks::ItemHandler.expects(:new).with(instance_of(Bot::Context)).returns(item_handler_mock)
    item_handler_mock.expects(:add_item_prompt).with(123)

    Bot::Callbacks.handle(@bot, build_callback('add_item:123'))
  end

  test 'handle ignores unknown routes' do
    Bot::Context.any_instance.stubs(:send_text)
    Bot::Callbacks::WishlistHandler.expects(:new).never
    Bot::Callbacks::ItemHandler.expects(:new).never

    Bot::Callbacks.handle(@bot, build_callback('unknown_route'))
  end

  test 'handle rescues from RecordNotFound' do
    Bot::Callbacks::WishlistHandler.stubs(:new).raises(ActiveRecord::RecordNotFound)
    Bot::Context.any_instance.expects(:send_text).with("Произошла ошибка. Попробуйте еще раз.")

    Bot::Callbacks.handle(@bot, build_callback('show_lists'))
  end

  test 'handle rescues from StandardError' do
    Bot::Callbacks::WishlistHandler.stubs(:new).raises(StandardError)
    Bot::Context.any_instance.expects(:send_text).with("Произошла ошибка. Попробуйте еще раз.")

    Bot::Callbacks.handle(@bot, build_callback('show_lists'))
  end
end