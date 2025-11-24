# frozen_string_literal: true

module Bot
  class Context
    include Helpers

    attr_reader :bot, :user, :source

    def initialize(bot:, user:, source:)
      @bot = bot
      @user = user
      @source = source
    end

    def chat_id
      # Message has `chat.id`, CallbackQuery has `message.chat.id` or `from.id`
      source.try(:message)&.chat&.id || source.try(:chat)&.id || source.from.id
    end

    # Helper to send text to the current chat
    def send_text(text, keyboard = nil)
      super(bot, chat_id, text, keyboard)
    end

    # Helper to edit the message a callback came from
    def edit_message(text, keyboard = nil)
      return unless source.is_a?(Telegram::Bot::Types::CallbackQuery) && source.message

      bot.api.edit_message_text(
        chat_id: chat_id,
        message_id: source.message.message_id,
        text: text,
        reply_markup: keyboard,
        parse_mode: "Markdown"
      )
    end

    # For StateHandler, which needs the message text
    def text
      source.is_a?(Telegram::Bot::Types::Message) ? source.text.to_s.strip : nil
    end

    # For Callback handlers, which need the callback data
    def callback_data
      source.is_a?(Telegram::Bot::Types::CallbackQuery) ? source.data : nil
    end
  end
end
