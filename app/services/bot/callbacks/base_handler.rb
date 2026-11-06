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
    end
  end
end
