# Deletion notifications were removed. Jobs already queued or waiting for a
# retry under this name finish quietly. Remove after the next release.
class ReservedGiftDeletedJob < ApplicationJob
  queue_as :notifications
  self.log_arguments = false

  def perform(*)
  end
end
