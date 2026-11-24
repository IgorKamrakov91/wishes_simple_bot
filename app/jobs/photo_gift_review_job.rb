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
    photo = draft.card_photo
    caption, parse_mode = Bot::Context.caption(text)
    if (message_id = draft.result["screen_message_id"])
      begin
        if draft.result["screen_photo"]
          return api.edit_message_caption(**{ chat_id: draft.chat_id, message_id: message_id, reply_markup: keyboard,
                                              caption: caption, parse_mode: parse_mode }.compact)
        elsif !photo
          return api.edit_message_text(chat_id: draft.chat_id, message_id: message_id, text: text, reply_markup: keyboard,
                                       parse_mode: "HTML", link_preview_options: no_link_preview)
        end
      rescue Telegram::Bot::Exceptions::ResponseError => e
        # A retry after a delivered edit whose reply was lost: already shown
        return if e.message.include?("message is not modified")
        # Deleted, too old or otherwise not editable: send it below instead.
        # Throttling is retried as a whole.
        raise if e.error_code.to_i == 429
      end
    end
    # A text screen can't become a photo card: a new card replaces it
    sent = if photo
      api.send_photo(**{ chat_id: draft.chat_id, photo: photo, caption: caption, reply_markup: keyboard,
                         parse_mode: parse_mode }.compact)
    else
      api.send_message(chat_id: draft.chat_id, text: text, reply_markup: keyboard, parse_mode: "HTML",
                       link_preview_options: no_link_preview)
    end
    draft.remember_screen!(sent.message_id, photo: photo.present?) if sent.respond_to?(:message_id)
  end
end
