module Bot
  module Callbacks
    # Undoing a photo gift that was saved on its own
    class PhotoGiftResultHandler < BaseHandler
      def undo(draft_id)
        raise ActiveRecord::RecordNotFound unless PhotoGiftDraft.enabled?

        draft = user.photo_gift_drafts.find(draft_id)
        item = draft.item if draft.status == "saved"
        return context.render(I18n.t("bot.photo_gift.undone")) unless item

        # Someone already reserved it: removing it here would surprise them
        if item.reserved?
          context.notice = I18n.t("bot.photo_gift.undo_reserved")
          return
        end

        item.destroy!
        context.render(I18n.t("bot.photo_gift.undone"))
      end
    end
  end
end
