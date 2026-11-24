require "telegram/bot"

# Sends the review of a recognized photo draft as a new message, so it
# appears below "looking at the photo" even if the person scrolled away.
# Retried when Telegram fails; skipped once the draft has moved on (saved,
# cancelled, replaced or edited), so a late review never shows up.
class PhotoGiftReviewJob < ApplicationJob
  include Bot::Helpers

  queue_as :default
  self.log_arguments = false
  retry_on Telegram::Bot::Exceptions::ResponseError, Faraday::Error, wait: 5.seconds, attempts: 3 do |job, error|
    Rails.logger.info("Photo gift #{job.arguments.first} review not delivered (#{error.class})")
  end

  def perform(draft_id, version)
    draft = PhotoGiftDraft.find_by(id: draft_id)
    return unless draft&.editable? && draft.version == version

    I18n.with_locale(draft.locale) do
      presenter = Bot::Presenters::PhotoGiftPresenter.new(draft, draft.user, self)
      Telegram::Bot::Client.new(ENV.fetch("TELEGRAM_BOT_TOKEN")).api.send_message(
        chat_id: draft.chat_id, text: presenter.text, reply_markup: presenter.keyboard,
        parse_mode: "HTML", link_preview_options: no_link_preview
      )
    end
  end
end
