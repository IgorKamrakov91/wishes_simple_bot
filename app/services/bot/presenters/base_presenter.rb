# frozen_string_literal: true

module Bot
  module Presenters
    class BasePresenter
      attr_reader :model, :user, :context

      def initialize(model, user, context)
        @model = model
        @user = user
        @context = context
      end

      def self.object_name(name)
        alias_method name, :model
      end
    end
  end
end
