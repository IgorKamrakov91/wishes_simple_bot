module Bot
  # Capture current bookings under the same locks as the deletion. Publish only
  # after commit, so rolled-back deletes cannot cancel a guest's plans.
  class ReservationDeletion
    class << self
      def destroy_item!(item)
        return if item.destroyed?

        item.with_lock do
          wishlist = item.wishlist
          recipient = item.reserved_by
          details = list_details(wishlist).merge("title" => item.title.to_s.truncate(100))
          item.destroy!
          enqueue_after_commit(recipient, wishlist, "item_deleted", details)
        end
      end

      def destroy_list!(wishlist)
        return if wishlist.destroyed?

        wishlist.with_lock do
          recipients = wishlist.items.lock.to_a.filter_map(&:reserved_by).uniq
          details = list_details(wishlist)
          wishlist.destroy!
          recipients.each { |recipient| enqueue_after_commit(recipient, wishlist, "list_deleted", details) }
        end
      end

      private

      def list_details(wishlist)
        { "list" => wishlist.title.to_s.truncate(100), "owner" => wishlist.owner.full_name.truncate(100) }
      end

      def enqueue_after_commit(recipient, wishlist, kind, details)
        return unless recipient && recipient != wishlist.owner.telegram_id

        locale = I18n.locale.to_s
        Item.current_transaction.after_commit do
          begin
            ReservedGiftDeletedJob.perform_later(recipient, kind, details, locale)
          rescue StandardError => e
            # A queue outage must not report the already-committed delete as a
            # failed action. No Telegram calls run in this request.
            Rails.logger.error("Could not enqueue reservation deletion notification (#{e.class})")
          end
        end
      end
    end
  end
end
