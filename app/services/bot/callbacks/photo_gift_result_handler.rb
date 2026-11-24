module Bot
  module Callbacks
    # Undoing a photo gift that was saved on its own
    class PhotoGiftResultHandler < BaseHandler
      def undo(draft_id)
        raise ActiveRecord::RecordNotFound unless PhotoGiftDraft.enabled?

        draft = user.photo_gift_drafts.find(draft_id)
        item = draft.item if draft.status == "saved"
        return context.render(I18n.t("bot.photo_gift.undone")) unless item

        # Checked and removed under the gift's lock, so a guest reserving it
        # at this moment either wins or finds it gone
        removed = item.with_lock do
          next false if item.reserved?

          item.destroy!
        end
        # Someone already reserved it: removing it here would surprise them
        return context.notice = I18n.t("bot.photo_gift.undo_reserved") unless removed

        context.render(I18n.t("bot.photo_gift.undone"))
      end
    end
  end
end
