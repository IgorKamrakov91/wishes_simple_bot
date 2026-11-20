require "telegram/bot"

class OnboardingNudgeJob < ApplicationJob
  include Bot::Helpers

  queue_as :reminders
  self.log_arguments = false
  limits_concurrency to: 2, key: "gift_ideas", group: "gift_ideas", duration: 2.minutes

  def perform(nudge_id)
    @nudge = OnboardingNudge.find_by(id: nudge_id)
    return unless @nudge && OnboardingNudge.ready.exists?(nudge_id)
    return unless due_now?
    return unless prepare_once
    return unless due_now?

    return unless OnboardingNudge.ready.where(id: nudge_id)
      .update_all([ "claimed_at = ?, attempts = attempts + 1", Time.current ]) == 1

    # No business row is held during either external call. Recheck the user
    # immediately before delivery, including a gift saved during generation.
    unless due_now?
      @nudge.update!(claimed_at: nil)
      return
    end
    I18n.with_locale(@nudge.locale) { send_nudge(@nudge.current_list) }
    @nudge.update!(sent_at: Time.current)
  rescue Telegram::Bot::Exceptions::ResponseError, Faraday::Error => e
    code = e.error_code.to_i if e.is_a?(Telegram::Bot::Exceptions::ResponseError)
    Rails.logger.info("Onboarding nudge delivery failed (#{code || e.class})")
    # An unknown timeout may have delivered: keep the claim. Retry only known
    # rejected deliveries, with saved ideas, and at most three attempts.
    return if code.nil? || [ 400, 403, 404 ].include?(code) || @nudge.reload.attempts >= 3

    wait = code == 429 ? e.data.dig("parameters", "retry_after").to_i : 30
    @nudge.update!(claimed_at: nil, retry_at: OnboardingNudge.next_send_at(Time.current + [ wait, 1 ].max.seconds))
  rescue ActiveRecord::RecordNotFound
    nil
  end

  private

  def due_now?
    @nudge.user.reload
    return false unless @nudge.eligible?

    at = OnboardingNudge.next_send_at([ Time.current, @nudge.due_at ].max)
    if at > Time.current
      @nudge.update!(retry_at: at)
      return false
    end
    true
  end

  def prepare_once
    @nudge.reload
    return true if @nudge.prepared_at

    claimed = OnboardingNudge.where(id: @nudge.id, preparing_at: nil, prepared_at: nil)
      .update_all(preparing_at: Time.current) == 1
    @nudge.reload
    unless claimed
      return false if @nudge.preparing_at > GiftSuggestion::STALE_AFTER.ago

      # A lost worker must not issue another request. Use a persisted answer
      # if it finished, otherwise finish preparation with fixed examples.
      request = @nudge.gift_suggestion
      ideas = request&.ready? ? request.titles.first(3) : @nudge.fallback
      request.fail!("stale") if request && %w[pending processing].include?(request.status)
      save_ideas(ideas)
      return true
    end

    request = nil
    @nudge.user.with_lock do
      return false unless @nudge.eligible?

      list = @nudge.current_list
      result = I18n.with_locale(@nudge.locale) { GiftSuggestion.request_system_for!(@nudge.user, list) } if list
      request = result&.suggestion
      @nudge.update!(wishlist: list, gift_suggestion: request)
    end
    ideas = @nudge.fallback
    if request&.claim!
      begin
        titles = YandexAi::GiftIdeas.new.call(@nudge.wishlist.title, [])
        request.finish!(titles.first(3))
        ideas = request.titles
      rescue StandardError => e
        request.fail!(e.is_a?(YandexAi::Client::Error) ? e.code : "error")
        Rails.logger.info("Onboarding idea request failed (#{e.class})")
      end
    end
    save_ideas(ideas)
    true
  end

  def save_ideas(ideas)
    OnboardingNudge.where(id: @nudge.id, prepared_at: nil).update_all(ideas: ideas, prepared_at: Time.current)
    @nudge.reload
  end

  def send_nudge(list)
    # A changed/deleted target uses fixed examples, never another AI call.
    if list.nil? || list.id != @nudge.wishlist_id
      @nudge.update!(wishlist: list, gift_suggestion: nil, ideas: @nudge.fallback)
    end
    key = list ? "empty_list" : "no_list"
    text = I18n.t("bot.onboarding_nudge.#{key}", list: escape_html(list&.title.to_s.truncate(Wishlist::TITLE_LIMIT)))
    text += "\n\n" + @nudge.ideas.map { |title| "• #{escape_html(title)}" }.join("\n")
    action = if @nudge.user.bot_state.present? then "resume_input"
    elsif list then "first_gift:#{list.id}"
    else "new_list"
    end
    rows = [ [ inline_btn(I18n.t("bot.onboarding_nudge.continue"), action, style: "primary") ] ]
    suggestion = @nudge.gift_suggestion
    if suggestion&.ready? && suggestion.wishlist_id == list&.id && suggestion.created_at >= GiftSuggestion::OPEN_FOR.ago
      rows << [ inline_btn(I18n.t("bot.gift_ideas.recent"), "show_gift_ideas:#{suggestion.id}") ]
    end
    rows << [ inline_btn(I18n.t("bot.onboarding_nudge.dismiss"), "set_setting:notify_onboarding:0") ]
    Telegram::Bot::Client.new(ENV.fetch("TELEGRAM_BOT_TOKEN")).api.send_message(
      chat_id: @nudge.user.telegram_id, text: text, parse_mode: "HTML", reply_markup: build_keyboard(rows), link_preview_options: no_link_preview
    )
  end
end
