module Bot
  module Callbacks
    # Undoing a photo gift that was saved on its own
    class PhotoGiftResultHandler < BaseHandler
      def undo(draft_id)
        raise ActiveRecord::RecordNotFound unless PhotoGiftDraft.enabled?

        draft = user.photo_gift_drafts.find(draft_id)
        item = draft.item if draft.status == "saved"
        return undone(draft.wishlist) unless item

        # Checked and removed under the gift's lock, so a guest reserving it
        # at this moment either wins or finds it gone
        removed = item.with_lock do
          next false if item.reserved?

          item.destroy!
        end
        # Someone already reserved it: removing it here would surprise them
        return context.notice = I18n.t("bot.photo_gift.undo_reserved") unless removed

        undone(item.wishlist)
      end

      private

      def undone(list)
        rows = []
        rows << [ inline_btn(I18n.t("bot.photo_gift.open_list", list: list.title.truncate(35)), "open_list:#{list.id}") ] if list
        rows << [ inline_btn(I18n.t("bot.buttons.back_to_menu"), "main_menu") ]
        context.render(I18n.t("bot.photo_gift.undone"), build_keyboard(rows))
      end
    end
  end
end
