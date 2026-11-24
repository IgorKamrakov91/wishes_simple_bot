module Bot
  module Callbacks
    # Buttons of the evening photo digest
    class PhotoInboxHandler < BaseHandler
      # Saves every named draft in the inbox to the list (0: a new "My wishes")
      def save_all(list_id)
        raise ActiveRecord::RecordNotFound unless PhotoGiftDraft.enabled?

        list_id = list_id.to_i
        target = user.wishlists.find(list_id) unless list_id.zero?
        saved = 0
        Presenters::PhotoInboxDigestPresenter.savable(user.photo_gift_drafts.active.order(:created_at).to_a).each do |draft|
          next unless draft.select_list!(list_id, expected_version: draft.version)

          status, item = draft.save_gift!(expected_version: draft.version)
          next unless status == :saved

          saved += 1
          target ||= item.wishlist # the new list made by the first save
          list_id = target.id
        end
        left = user.photo_gift_drafts.active.count
        text = [ I18n.t("bot.photo_inbox.saved", count: saved, list: escape_html(target&.title.to_s)) ]
        text << I18n.t("bot.photo_inbox.left", count: left) if left.positive?
        rows = [ [ inline_btn(I18n.t("bot.buttons.open_list"), "open_list:#{target.id}") ] ] if target
        rows = (rows || []) + [ [ inline_btn(I18n.t("bot.photo_inbox.one_by_one"), "pgi:0") ] ] if left.positive?
        context.render(text.join("\n\n"), build_keyboard(rows || []))
      end

      # The person never answered the first photo: allow recognition now and
      # read everything that waited
      def consent
        raise ActiveRecord::RecordNotFound unless PhotoGiftDraft.enabled?

        started = user.photo_gift_drafts.active.where(status: "awaiting_consent").count
        # Consenting starts every waiting photo (User#recognize_waiting_photos)
        user.update!(photo_ai_consented_at: Time.current) unless user.photo_ai_consented_at?
        context.render(I18n.t("bot.photo_inbox.recognizing", count: started))
      end
    end
  end
end
