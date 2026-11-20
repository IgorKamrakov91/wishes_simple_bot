# First observations, not an event log or proof that a card was sent.
module OnboardingFunnel
  extend ActiveSupport::Concern

  TIMESTAMP_FIELDS = %w[first_private_start_at first_list_at first_item_at
    first_share_query_at first_shared_list_open_at].freeze
  FIELDS = (%w[onboarding_eligible first_contact_at first_contact_kind acquisition_source] + TIMESTAMP_FIELDS).freeze

  def onboarding?
    onboarding_eligible? && first_item_at.nil?
  end

  # Contact and campaign attribution are independent: a person may first use
  # inline mode, then start the private chat from a tagged link. Keep the
  # first observed tag without relabelling that original contact.
  def record_contact!(kind:, source: nil, private_start: false)
    return unless onboarding_eligible?

    with_lock do
      next unless onboarding_eligible?

      attributes = {}
      if first_contact_at.nil?
        attributes[:first_contact_at] = Time.current
        attributes[:first_contact_kind] = kind
      end
      attributes[:acquisition_source] = source if acquisition_source.nil? && source.present?
      attributes[:first_private_start_at] = Time.current if private_start && first_private_start_at.nil?
      update_columns(attributes) if attributes.any?
    end
  end

  # Called inside the creation transaction, including manual and AI gifts.
  # The conditional write serializes competing first saves on the user row.
  def record_first_funnel_event!(field, at: Time.current)
    field = field.to_s
    raise ArgumentError, "Unknown funnel field" unless TIMESTAMP_FIELDS.include?(field)

    changed = self.class.where(id: id, field => nil).update_all(field => at)
    if changed == 1
      self[field] = at
      clear_attribute_changes([ field ])
    end
  end

  def reset_onboarding!
    with_lock do
      before = attributes.slice(*FIELDS)
      update_columns(FIELDS.index_with { |field| field == "onboarding_eligible" ? true : nil })
      [ before, attributes.slice(*FIELDS) ]
    end
  end
end
