module Bot
  class Dispatcher
    def self.dispatch(bot, update)
      if update.message
        return unless PrivateChatGate.allow_message?(bot, update.message)

        UpdateDelivery.call(bot, update) { Commands.handle(bot, update.message) }
      elsif update.callback_query
        return unless PrivateChatGate.allow_callback?(bot, update.callback_query)

        if update.callback_query.inline_message_id
          Callbacks.handle(bot, update.callback_query)
        else
          UpdateDelivery.call(bot, update) { Callbacks.handle(bot, update.callback_query) }
        end
      elsif update.inline_query
        Inline.handle_query(bot, update.inline_query)
      else
        # Only the kind of update: its contents may be personal
        Rails.logger.info "Unknown update type: #{update.to_h.keys.excluding(:update_id).join(', ')}"
      end
    end
  end
end
