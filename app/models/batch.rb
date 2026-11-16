class Batch < ApplicationRecord
  belongs_to :shop
  belongs_to :previous, class_name: "Batch", optional: true
  has_one :revision, class_name: "Batch", foreign_key: :previous_id
  has_many :orders, class_name: "BatchOrder"
  has_many :audit_events
  serialize :rows, coder: JSON
  encrypts :rows

  scope :dispatchable, -> { where.not(confirmed_at: nil).where(paused_at: nil) }

  def audit!(action, actor:, order: nil, **details)
    audit_events.create!(action: action, actor: actor, batch_order_id: order&.id, details: details)
  end

  def duplicate_references(entries = orders)
    fingerprints = entries.map(&:fingerprint)
    previous_fingerprints = shop.batch_orders.joins(:batch)
      .where.not(batches: { confirmed_at: nil }).where.not(batch_id: id)
      .where(fingerprint: fingerprints).distinct.pluck(:fingerprint).to_set
    repeated = fingerprints.tally.select { |_fingerprint, count| count > 1 }
    entries.filter_map do |entry|
      entry.reference if previous_fingerprints.include?(entry.fingerprint) || repeated.key?(entry.fingerprint)
    end
  end

  def state(counts)
    return "superseded" if superseded_at
    return issues.empty? ? "ready" : "needs_changes" unless confirmed_at
    return "paused" if paused_at
    return "processing" if counts.fetch("pending", 0).positive? || counts.fetch("running", 0).positive?
    return "needs_review" if counts.fetch("review", 0).positive? || counts.fetch("failed", 0).positive?

    "finished"
  end
end
