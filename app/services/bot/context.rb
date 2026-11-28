# frozen_string_literal: true

module Bot
  class Context
    include Helpers

    # Telegram sizes a message, and the buttons under it, by its longest
    # line, so screens jumped in width as the user moved around. A blank
    # line of braille spaces (U+2800, which Telegram doesn't trim) makes
    # every screen with buttons about as wide as a phone allows; it stays a
    # little short of that so the time still fits beside it.
    SCREEN_WIDTH_LINE = "\u2800" * 23
    MESSAGE_LIMIT = 4096

    attr_reader :bot, :user, :source

    # Short text shown as a toast when the callback query is answered
    attr_accessor :notice
    attr_writer :guest_budget

    # Also recover navigation from the original button on webhook redelivery.
    def guest_budget
      return @guest_budget if defined?(@guest_budget)

      @guest_budget = GuestList.budget_from_callback(callback_data)
    end

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
      if (delivery = UpdateDelivery.current)
        return delivery.defer { send_text(text, keyboard, parse_mode: parse_mode, link_preview_options: link_preview_options) }
      end

      super(bot, chat_id, widen(text, keyboard), keyboard, parse_mode: parse_mode, link_preview_options: link_preview_options)
    end

    # Helper to edit the message a callback came from
    def edit_message(text, keyboard = nil, parse_mode: nil, link_preview_options: nil)
      if (delivery = UpdateDelivery.current)
        return delivery.defer { edit_message(text, keyboard, parse_mode: parse_mode, link_preview_options: link_preview_options) }
      end

      return unless editable_message?

      bot.api.edit_message_text(**{
        chat_id: chat_id,
        message_id: source.message.message_id,
        text: widen(text, keyboard),
        reply_markup: keyboard,
        parse_mode: parse_mode,
        link_preview_options: link_preview_options
      }.compact)
    end

    # Shows a screen: buttons update the message they belong to in place,
    # commands and typed replies get a new message.
    def render(text, keyboard = nil, link_preview_options: no_link_preview)
      if (delivery = UpdateDelivery.current)
        return delivery.defer { render(text, keyboard, link_preview_options: link_preview_options) }
      end

      if editable_message?
        edit_message(text, keyboard, parse_mode: "HTML", link_preview_options: link_preview_options)
      else
        send_text(text, keyboard, parse_mode: "HTML", link_preview_options: link_preview_options)
      end
    rescue Telegram::Bot::Exceptions::ResponseError => e
      raise unless editable_message?
      return if e.message.include?("message is not modified")
      raise if e.error_code.to_i == 429

      # Old messages can't be edited anymore, show the screen as a new one
      send_text(text, keyboard, parse_mode: "HTML", link_preview_options: link_preview_options)
    end

    # Capture the actual bot message after deferred delivery (outside the
    # business transaction). Callback edits retain their existing message id;
    # a failed edit falls back to a new message and records that id instead.
    def render_photo_gift(draft, text, keyboard)
      if (delivery = UpdateDelivery.current)
        return delivery.defer { render_photo_gift(draft, text, keyboard) }
      end

      if (photo = draft.card_photo)
        id = render_card(photo, text, keyboard)
        draft.remember_screen!(id, photo: true)
        return id
      end

      response = render(text, keyboard)
      id = response.message_id if response.respond_to?(:message_id)
      id ||= source.message.message_id if editable_message? && response.nil?
      draft.remember_screen!(id)
      response
    end

    CAPTION_LIMIT = 1024

    # Telegram limits captions to 1024 characters. Cutting HTML can split a
    # tag or an entity and get the card rejected, so a caption that doesn\x27t
    # fit goes as plain text, cut. Returns the caption and its parse mode.
    def self.caption(html)
      return [ html, "HTML" ] if html.length <= CAPTION_LIMIT

      [ CGI.unescapeHTML(html.gsub(/<[^>]*>/, "")).truncate(CAPTION_LIMIT), nil ]
    end

    # The draft's screens are a photo card: the picture with the text as its
    # caption. Buttons on the card change the caption in place; anywhere else
    # (a typed reply, a text screen) a new card is sent, since Telegram can't
    # turn a text message into a photo. Returns the card's message id.
    def render_card(photo, text, keyboard)
      caption, parse_mode = self.class.caption(text.to_s)
      if editable_message? && source.message.photo.present?
        begin
          bot.api.edit_message_caption(**{ chat_id: chat_id, message_id: source.message.message_id, caption: caption,
                                           reply_markup: keyboard, parse_mode: parse_mode }.compact)
          return source.message.message_id
        rescue Telegram::Bot::Exceptions::ResponseError => e
          return source.message.message_id if e.message.include?("message is not modified")
          raise if e.error_code.to_i == 429
        end
      end
      bot.api.send_photo(**{ chat_id: chat_id, photo: photo, caption: caption, reply_markup: keyboard,
                             parse_mode: parse_mode }.compact).message_id
    end

    # Captions on forwarded store photos/documents are usable input too.
    # Only their text is consumed; attachments are not stored.
    def text
      return unless source.is_a?(Telegram::Bot::Types::Message)

      (source.text.presence || source.caption).to_s.strip
    end

    # A photo, sticker or other message without usable text or a caption
    def non_text_message?
      source.is_a?(Telegram::Bot::Types::Message) && source.text.nil? && source.caption.blank?
    end

    # For Callback handlers, which need the callback data
    def callback_data
      source.is_a?(Telegram::Bot::Types::CallbackQuery) ? source.data : nil
    end

    # Reuse Telegram's file, never forward the uploader's original message.
    def send_photo(file_id)
      return UpdateDelivery.current.defer { send_photo(file_id) } if UpdateDelivery.current

      bot.api.send_photo(chat_id: chat_id, photo: file_id)
    rescue Telegram::Bot::Exceptions::ResponseError, Faraday::Error
      send_text(I18n.t("bot.photo_gift.photo_unavailable"))
    end

    private

    # Telegram counts the limit in UTF-16 units after parsing the markup;
    # the source text is never shorter, so a long screen just stays narrow
    def widen(text, keyboard)
      return text unless keyboard

      widened = "#{text}\n#{SCREEN_WIDTH_LINE}"
      widened.encode("UTF-16LE").bytesize / 2 <= MESSAGE_LIMIT ? widened : text
    end

    def editable_message?
      source.is_a?(Telegram::Bot::Types::CallbackQuery) && source.message&.message_id.present?
    end
  end
end
