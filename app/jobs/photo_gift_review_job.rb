require "telegram/bot"

# Shows the outcome of recognition: the review, or the gift saved on its own
# when a list had been picked. It replaces the "got it" message the bot sent
# for the photo, and is sent anew when that message can't be edited. Retried
# when Telegram fails; skipped once the draft has moved on (cancelled,
# replaced or edited), so a late screen never shows up.
class PhotoGiftReviewJob < ApplicationJob
  include Bot::Helpers

  queue_as :default
  self.log_arguments = false
  retry_on Telegram::Bot::Exceptions::ResponseError, Faraday::Error, wait: 5.seconds, attempts: 3 do |job, error|
    Rails.logger.info("Photo gift #{job.arguments.first} review not delivered (#{error.class})")
  end

  def perform(draft_id, version)
    draft = PhotoGiftDraft.find_by(id: draft_id)
    return unless draft && draft.version == version
    return unless draft.editable? || (draft.status == "saved" && draft.item)

    I18n.with_locale(draft.locale) do
      presenter = if draft.status == "saved"
        Bot::Presenters::PhotoGiftAddedPresenter.new(draft, draft.user, self)
      else
        Bot::Presenters::PhotoGiftPresenter.new(draft, draft.user, self)
      end
      show(draft, presenter.text, presenter.keyboard)
    end
  end

  private

  def show(draft, text, keyboard)
    api = Telegram::Bot::Client.new(ENV.fetch("TELEGRAM_BOT_TOKEN")).api
    screen = { chat_id: draft.chat_id, text: text, reply_markup: keyboard, parse_mode: "HTML",
               link_preview_options: no_link_preview }
    if (message_id = draft.result["screen_message_id"])
      begin
        return api.edit_message_text(**screen, message_id: message_id)
      rescue Telegram::Bot::Exceptions::ResponseError => e
        # Deleted, too old or otherwise not editable: send it below instead.
        # Throttling is retried as a whole.
        raise if e.error_code.to_i == 429
      end
    end
    api.send_message(**screen)
  end
end
