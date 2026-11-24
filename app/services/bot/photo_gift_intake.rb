module Bot
  class PhotoGiftIntake
    MAX_BYTES = 10.megabytes
    MAX_PIXELS = 40_000_000

    def initialize(context)
      @context = context
    end

    def handle
      return false unless PhotoGiftDraft.enabled?
      return false unless message.is_a?(Telegram::Bot::Types::Message) && message.chat.type == "private"
      return false if context.text.start_with?("/")
      return false unless message.photo.present? || message.document
      return false unless user.bot_state.blank? || %w[adding_item photo_gift].include?(user.bot_state)

      # Album integration remains deliberately small: one draft per album,
      # even when Telegram delivers its messages out of order or repeats them.
      if message.media_group_id && (draft = user.photo_gift_drafts.find_by(media_group_id: message.media_group_id))
        draft.with_lock do
          if message.message_id != draft.message_id && !draft.result["album_notice_sent"]
            draft.update!(result: draft.result.merge("album_notice_sent" => true))
            context.send_text(I18n.t("bot.photo_gift.one_photo"))
          end
        end
        return true
      end
      media = message.photo&.max_by { |photo| photo.width * photo.height } || message.document
      document = message.photo.blank?
      if media.file_size.to_i > MAX_BYTES || (document && !%w[image/jpeg image/png].include?(media.mime_type)) ||
          (!document && media.width * media.height > MAX_PIXELS)
        context.send_text(I18n.t("bot.photo_gift.unsupported"))
        return true
      end

      draft = PhotoGiftDraft.start!(user, chat_id: context.chat_id, message_id: message.message_id,
        media_group_id: message.media_group_id, file_id: media.file_id, file_unique_id: media.file_unique_id,
        photo_file_id: (media.file_id unless document), media_kind: document ? "document" : "photo",
        media_status: document ? "pending" : "ready", caption: message.caption)
      if document
        ActiveRecord.after_all_transactions_commit { PhotoGiftDocumentJob.perform_later(draft.id) }
      end
      Callbacks::PhotoGiftHandler.new(context).show(draft.id)
      true
    end

    private

    attr_reader :context

    def user
      context.user
    end

    def message
      context.source
    end
  end
end
