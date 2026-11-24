require "telegram/bot"

# The evening digest for one person: what was photographed and left, with
# saving everything to a list in one tap, or allowing recognition when the
# person never answered the first question.
class PhotoInboxDigestJob < ApplicationJob
  include Bot::Helpers

  queue_as :reminders
  self.log_arguments = false

  def perform(user_id)
    user = User.find_by(id: user_id)
    return unless user && PhotoGiftDraft.enabled?

    drafts = claim(user)
    return if drafts.empty?

    inbox = user.photo_gift_drafts.active.order(:created_at).to_a
    I18n.with_locale(drafts.last.locale) do
      presenter = Bot::Presenters::PhotoInboxDigestPresenter.new(inbox, user, self)
      Telegram::Bot::Client.new(ENV.fetch("TELEGRAM_BOT_TOKEN")).api.send_message(
        chat_id: user.telegram_id, text: presenter.text, reply_markup: presenter.keyboard,
        parse_mode: "HTML", link_preview_options: no_link_preview
      )
    end
  rescue Telegram::Bot::Exceptions::ResponseError, Faraday::Error => e
    # The drafts stay in the inbox; tomorrow's digest won't repeat them
    Rails.logger.info("Photo inbox digest not delivered (#{e.class})")
  end

  private

  # Marks the person's new drafts as digested, so a repeated job sends nothing
  def claim(user)
    user.with_lock do
      drafts = user.photo_gift_drafts.for_digest.to_a
      # In SQL, so an edit the person makes right now isn't overwritten
      PhotoGiftDraft.where(id: drafts.map(&:id))
        .update_all([ "result = result || jsonb_build_object('digested_at', ?::text)", Time.current.iso8601 ])
      drafts
    end
  end
end
