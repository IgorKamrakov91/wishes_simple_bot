# frozen_string_literal: true

module Bot
  class Context
    include Helpers

    attr_reader :bot, :user, :source

    # Short text shown as a toast when the callback query is answered
    attr_accessor :notice

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
    def send_text(text, keyboard = nil, parse_mode: nil, link_preview_options: nil)
      super(bot, chat_id, text, keyboard, parse_mode: parse_mode, link_preview_options: link_preview_options)
    end

    # Helper to edit the message a callback came from
    def edit_message(text, keyboard = nil, parse_mode: nil, link_preview_options: nil)
      return unless editable_message?

      bot.api.edit_message_text(**{
        chat_id: chat_id,
        message_id: source.message.message_id,
        text: text,
        reply_markup: keyboard,
        parse_mode: parse_mode,
        link_preview_options: link_preview_options
      }.compact)
    end

    # Shows a screen: buttons update the message they belong to in place,
    # commands and typed replies get a new message.
    def render(text, keyboard = nil, link_preview_options: no_link_preview)
      if editable_message?
        edit_message(text, keyboard, parse_mode: "HTML", link_preview_options: link_preview_options)
      else
        send_text(text, keyboard, parse_mode: "HTML", link_preview_options: link_preview_options)
      end
    rescue Telegram::Bot::Exceptions::ResponseError => e
      raise unless editable_message?
      return if e.message.include?("message is not modified")

      # Old messages can't be edited anymore, show the screen as a new one
      send_text(text, keyboard, parse_mode: "HTML", link_preview_options: link_preview_options)
    end

    # For StateHandler, which needs the message text
    def text
      source.is_a?(Telegram::Bot::Types::Message) ? source.text.to_s.strip : nil
    end

    # For Callback handlers, which need the callback data
    def callback_data
      source.is_a?(Telegram::Bot::Types::CallbackQuery) ? source.data : nil
    end

    private

    def editable_message?
      source.is_a?(Telegram::Bot::Types::CallbackQuery) && source.message&.message_id.present?
    end
  end
end
