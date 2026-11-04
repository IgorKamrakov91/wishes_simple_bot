# frozen_string_literal: true

module Bot
  module Callbacks
    class BaseHandler
      include Helpers

      attr_reader :context, :bot, :user, :chat_id

      def initialize(context)
        @context = context
        @bot = context.bot
        @user = context.user
        @chat_id = context.chat_id
      end

      private

      def cancel_keyboard(callback_data)
        context.build_keyboard([ [ context.inline_btn(I18n.t("bot.buttons.cancel"), callback_data) ] ])
      end
    end
  end
end
