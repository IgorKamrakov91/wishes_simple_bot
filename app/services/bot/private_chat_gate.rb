module Bot
  # Check the delivery chat before handlers can read private data or change a
  # user's input state. Inline invitations are public cards, not private UI.
  class PrivateChatGate
    extend Helpers

    GROUP_TYPES = %w[group supergroup].freeze
    COMMANDS = %w[start my new reservations settings help cancel].freeze

    class << self
      def allow_message?(bot, message)
        return true if message.chat.type == "private"

        if GROUP_TYPES.include?(message.chat.type) && addressed_command?(message.text.to_s)
          show_private_chat_link(bot, message.chat.id, url: invitation_link(message.text.to_s))
        end
        false
      end

      def allow_callback?(bot, callback)
        # These old inline buttons only return a share URL after the existing
        # access check. No other inline callback may invoke private actions.
        return true if callback.inline_message_id && callback.data.to_s.match?(/\Aopen_shared_list:\d+\z/)
        return true if !callback.inline_message_id && callback.message&.chat&.type == "private"

        chat = callback.message&.chat
        show_private_chat_link(bot, chat.id) if GROUP_TYPES.include?(chat&.type)
        safely do
          bot.api.answer_callback_query(callback_query_id: callback.id,
                                        text: I18n.t("bot.messages.private_chat_only"), show_alert: true)
        end
        false
      end

      private

      def addressed_command?(text)
        match = text.match(/\A\/(\w+)(?:@(\w+))?(?:\s|\z)/)
        return false unless match

        command, recipient = match.captures
        if recipient
          recipient.casecmp?(bot_link.split("/").last)
        else
          COMMANDS.include?(command)
        end
      end

      def invitation_link(text)
        command, payload = text.split(/\s+/, 2)
        return bot_link unless command.match?(%r{\A/start(?:@\w+)?\z}) && payload

        payload = payload.strip
        return bot_link if payload.length > 64

        start = "/start #{payload}"
        return bot_link unless Commands::START_SHARED_LIST_PATTERN.match?(start) || Commands::START_LEGACY_LIST_PATTERN.match?(start)

        "#{bot_link}?start=#{payload}"
      end

      def show_private_chat_link(bot, chat_id, url: bot_link)
        keyboard = build_keyboard([ [ inline_btn(I18n.t("bot.buttons.open_private_chat"), url: url) ] ])
        safely do
          bot.api.send_message(chat_id: chat_id, text: I18n.t("bot.messages.private_chat_only"),
                               reply_markup: keyboard, link_preview_options: no_link_preview)
        end
      end

      # A denied callback still stays denied when the prompt or its expired
      # acknowledgement cannot be delivered. Never turn this into a retry.
      def safely
        yield
      rescue Telegram::Bot::Exceptions::ResponseError, Faraday::Error => e
        Rails.logger.warn("Could not deliver private chat prompt: #{e.message}")
      end
    end
  end
end
