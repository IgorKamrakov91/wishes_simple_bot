module Bot
  class Dispatcher
    class << self
      def dispatch(bot, update)
        case update
        when Telegram::Bot::Types::Message
          Commands.handle(bot, update)
        when Telegram::Bot::Types::CallbackQuery
          Callbacks.handle(bot, update)
        when Telegram::Bot::Types::InlineQuery
          Inline.handle_query(bot, update)
        when Telegram::Bot::Types::ChosenInlineResult
          Inline.handle_chosen(bot, update)
        else
          Rails.logger.info "Unknown update type: #{update.inspect}"
        end
      end
    end
  end
end
