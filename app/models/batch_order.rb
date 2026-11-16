class BatchOrder < ApplicationRecord
  belongs_to :batch
  serialize :request_data, coder: JSON
  encrypts :request_data

  scope :due, -> { where(status: "pending").where("next_attempt_at IS NULL OR next_attempt_at <= ?", Time.current) }
  scope :stale, -> { where(status: "running", started_at: ..2.minutes.ago) }
  scope :sync_due, -> { where(status: %w[succeeded review]).where(sync_at: ..Time.current) }

  def update_remote!(remote)
    timestamp = Time.iso8601(remote.fetch("updatedAt"))
    return if remote_updated_at && timestamp <= remote_updated_at
    return if remote_status == "DELETED"

    status_changed = remote_status != remote.fetch("status")
    update!(status: "succeeded", remote_id: remote.fetch("id"), remote_name: remote.fetch("name"),
            remote_status: remote.fetch("status"), remote_updated_at: timestamp,
            error_code: nil, sync_at: next_sync(remote.fetch("status")))
    batch.audit!("shopify_status", actor: "worker", order: self, status: remote_status) if status_changed
  end

  def next_sync(state = remote_status)
    state.in?(%w[COMPLETED DELETED]) ? nil : 1.hour.from_now
  end
end
