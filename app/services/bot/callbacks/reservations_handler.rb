# frozen_string_literal: true

module Bot
  module Callbacks
    class ReservationsHandler < BaseHandler
      def show_reservations(page = 0)
        presenter = Presenters::ReservationsPresenter.new(user, context, page: page)
        context.render(presenter.text, presenter.keyboard)
      end

      def open_item(item_id, page)
        ItemHandler.new(context).show_item(item_id, reservations_page: page)
      rescue ActiveRecord::RecordNotFound
        context.notice = I18n.t("bot.messages.button_outdated")
        show_reservations(page)
      end

      def release(item_id, reservation_version, page)
        ItemHandler.new(context).unreserve_item(item_id, reservation_version, page)
      rescue ActiveRecord::RecordNotFound
        context.notice = I18n.t("bot.messages.not_available")
        show_reservations(page)
      end
    end
  end
end
