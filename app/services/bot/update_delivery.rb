# frozen_string_literal: true

module Bot
  # The receipt and all business changes commit together. Replies are kept
  # only in memory and sent afterwards; neither text nor payload is persisted.
  class UpdateDelivery
    include Helpers

    class ActorMismatch < StandardError; end

    class << self
      def current
        ActiveSupport::IsolatedExecutionState[:bot_update_delivery]
      end

      def record_result(kind, id = nil)
        current&.record_result(kind, id)
      end

      def record_view(kind, id)
        current&.record_view(kind, id)
      end

      def call(bot, update)
        return yield unless update.update_id

        new(bot, update).call { yield }
      end
    end

    def initialize(bot, update)
      @bot = bot
      @update = update
      @source = update.message || update.callback_query
      @responses = []
    end

    def defer(&response)
      @responses << response
      nil
    end

    def record_result(kind, id)
      @receipt.update!(result_kind: kind, result_id: id)
    end

    def record_view(kind, id)
      record_result(kind, id) if @receipt.result_kind == "processed"
    end

    def call
      fresh = false
      BotUpdateReceipt.transaction do
        @receipt = BotUpdateReceipt.create_or_find_by!(update_id: @update.update_id) do |receipt|
          receipt.telegram_user_id = @source.from.id
        end
        fresh = @receipt.previously_new_record?
        raise ActorMismatch unless @receipt.telegram_user_id == @source.from.id

        capture { yield } if fresh
      end
      deliver(replay: !fresh)
    rescue StandardError => e
      log_failure("processing", e)
      reply_with_failure(I18n.t("bot.commands.message_failed"))
    end

    private

    def capture
      previous = self.class.current
      ActiveSupport::IsolatedExecutionState[:bot_update_delivery] = self
      yield
    ensure
      ActiveSupport::IsolatedExecutionState[:bot_update_delivery] = previous
    end

    def deliver(replay:)
      # Only this technical row stays locked during delivery. Business rows
      # have already committed. A competing replay waits, then checks the flag;
      # a crashed process releases the lock without marking the reply delivered.
      @receipt.with_lock do
        if @receipt.delivered_at
          acknowledge_replay if replay
          return
        end

        if replay
          UpdateResultReply.new(@bot, @source, @receipt).render
          acknowledge_replay
        else
          @responses.each(&:call)
        end
        @receipt.mark_delivered!
      end
    rescue StandardError => e
      log_failure("delivery", e)
      result = I18n.t("bot.messages.update_results.#{@receipt.result_kind}")
      reply_with_failure("#{result}\n#{I18n.t('bot.messages.result_screen_failed')}")
    end

    def acknowledge_replay
      return unless @source.is_a?(Telegram::Bot::Types::CallbackQuery)

      @bot.api.answer_callback_query(callback_query_id: @source.id)
    rescue Telegram::Bot::Exceptions::ResponseError, Faraday::Error => e
      log_failure("acknowledgement", e)
    end

    def reply_with_failure(text)
      if @source.is_a?(Telegram::Bot::Types::CallbackQuery)
        @bot.api.answer_callback_query(callback_query_id: @source.id, text: text.truncate(200), show_alert: true)
      else
        keyboard = build_keyboard([
          [ inline_btn(I18n.t("bot.buttons.my_lists"), "show_lists"),
            inline_btn(I18n.t("bot.screens.reservations.title"), "show_reservations") ],
          [ inline_btn(I18n.t("bot.buttons.back_to_menu"), "main_menu"), inline_btn(I18n.t("bot.buttons.help"), "help") ]
        ])
        Context.new(bot: @bot, user: nil, source: @source).send_text(text, keyboard)
      end
    rescue StandardError => e
      log_failure("fallback", e)
    end

    def log_failure(stage, error)
      Rails.logger.error("Bot update #{@update.update_id} #{stage} failed (#{error.class})")
    end
  end
end
