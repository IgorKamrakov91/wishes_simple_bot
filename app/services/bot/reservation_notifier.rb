# frozen_string_literal: true

module Bot
  # Tells the list owner and the list's guests that a gift was reserved or
  # released, each according to their settings. Nobody is told who did it,
  # and the person who pressed the button is not notified.
  module ReservationNotifier
    module_function

    def reserved(item, by:)
      notify(item, by, "reserved")
    end

    def released(item, by:)
      notify(item, by, "released")
    end

    def notify(item, actor, event)
      wishlist = item.wishlist
      owner = wishlist.owner
      details = { "wishlist_id" => wishlist.id, "item_id" => item.id,
                  "title" => item.title.to_s.truncate(100), "list" => wishlist.title.to_s.truncate(100),
                  "owner" => (owner.first_name.presence || owner.full_name).truncate(100) }

      enqueue(owner, "own_#{event}", details) if owner.notify_own_reservations && owner != actor

      wishlist.viewers.where(notify_friend_reservations: true).where.not(id: [ actor.id, owner.id ]).find_each do |guest|
        enqueue(guest, "friend_#{event}", details)
      end
    end

    # Only after the reservation is committed (right away when there is no
    # transaction), and a queue outage must not fail the button press
    def enqueue(recipient, kind, details)
      locale = I18n.locale.to_s
      ActiveRecord.after_all_transactions_commit do
        NotificationJob.perform_later(recipient.telegram_id, kind, details, locale)
      rescue StandardError => e
        Rails.logger.error("Could not enqueue #{kind} notification (#{e.class})")
      end
    end
  end
end
