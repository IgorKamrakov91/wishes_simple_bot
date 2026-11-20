require "test_helper"
require "telegram/bot"
require "timeout"

class BotOnboardingIdeasConcurrencyTest < ActiveSupport::TestCase
  self.use_transactional_tests = false

  class QuietContext < Bot::Context
    def render(*)
    end
  end

  setup do
    @owner = User.create!(telegram_id: 97609, first_name: "Owner")
    @list = @owner.wishlists.create!(title: "Birthday")
    @owner.update!(bot_state: "adding_item", bot_payload: { "wishlist_id" => @list.id, "first_item" => true })
    @suggestion = GiftSuggestion.create!(user: @owner, wishlist: @list, status: "ready", ideas: [ { "title" => "Lamp" } ])
    @previous_env = %w[YANDEX_AI_API_KEY YANDEX_AI_FOLDER_ID YANDEX_AI_ENABLED].to_h { |key| [ key, ENV[key] ] }
    ENV["YANDEX_AI_API_KEY"] = "test"
    ENV["YANDEX_AI_FOLDER_ID"] = "test"
    ENV["YANDEX_AI_ENABLED"] = "true"
  end

  teardown do
    @previous_env.each { |key, value| value.nil? ? ENV.delete(key) : ENV[key] = value }
    @owner.destroy!
  end

  test "two simultaneous choices from the same empty input save one gift" do
    ready = Queue.new
    start = Queue.new
    requests = 2.times.map do
      Thread.new do
        ActiveRecord::Base.connection_pool.with_connection do
          user = User.find(@owner.id)
          source = Telegram::Bot::Types::CallbackQuery.new(
            id: "choice", chat_instance: "chat", data: "noop",
            from: { id: user.telegram_id, is_bot: false, first_name: "Owner" }
          )
          context = QuietContext.new(bot: nil, user: user, source: source)
          ready << true
          start.pop
          Bot::Callbacks::GiftIdeasHandler.new(context).add_idea(@suggestion.id, 0)
        end
      end
    end

    Timeout.timeout(10) do
      2.times { ready.pop }
      2.times { start << true }
      requests.each(&:value)
    end

    item = @list.items.sole
    assert_equal "Lamp", item.title
    assert_nil @owner.reload.bot_state
    assert_equal item.created_at, @owner.first_item_at
    assert_equal item.id, @suggestion.reload.ideas.sole.fetch("item_id")
  ensure
    requests&.each do |thread|
      thread.kill if thread.alive?
      thread.join
    end
  end
end
