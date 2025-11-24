# frozen_string_literal: true

module Bot
  module Callbacks
    class BaseHandler
      attr_reader :context, :bot, :user, :chat_id

      def initialize(context)
        @context = context
        @bot = context.bot
        @user = context.user
        @chat_id = context.chat_id
      end

      private

      def notify_viewers(wishlist, message)
        return if wishlist.list_viewers.empty?

        # This is a candidate for a future refactoring into a Notifier service.
        bot_client = Telegram::Bot::Client.new(ENV.fetch("TELEGRAM_BOT_TOKEN"))
        wishlist.list_viewers.includes(:user).distinct.each do |viewer|
          next unless viewer.user&.telegram_id.present?

          send_notification(bot_client, viewer.user.telegram_id, message)
        end
      end

      def send_notification(bot_client, chat_id, message)
        bot_client.api.send_message(chat_id: chat_id, text: message)
      rescue Telegram::Bot::Exceptions::ResponseError => e
        Rails.logger.error("Failed to send telegram notification: #{e.message}")
      end
    end
  end
end
