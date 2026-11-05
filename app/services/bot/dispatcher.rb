module Bot
  class Dispatcher
    def self.dispatch(bot, update)
      if update.message
        return unless PrivateChatGate.allow_message?(bot, update.message)

        Commands.handle(bot, update.message)
      elsif update.callback_query
        return unless PrivateChatGate.allow_callback?(bot, update.callback_query)

        Callbacks.handle(bot, update.callback_query)
      elsif update.inline_query
        Inline.handle_query(bot, update.inline_query)
      else
        # Only the kind of update: its contents may be personal
        Rails.logger.info "Unknown update type: #{update.to_h.keys.excluding(:update_id).join(', ')}"
      end
    end
  end
end
