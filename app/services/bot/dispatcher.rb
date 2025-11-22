module Bot
  class Dispatcher
    def self.dispatch(bot, update)
      if update.message
        Commands.handle(bot, update.message)
      elsif update.callback_query
        Callbacks.handle(bot, update.callback_query)
      elsif update.inline_query
        Inline.handle_query(bot, update.inline_query)
      elsif update.chosen_inline_result
        Inline.handle_chosen(bot, update.chosen_inline_result)
      else
        Rails.logger.info "Unknown update type: #{update.inspect}"
      end
    end
  end
end
