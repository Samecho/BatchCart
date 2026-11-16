class RunShopJob < ApplicationJob
  def perform(shop_id)
    shop = Shop.find(shop_id)
    ran = shop.with_api_lock do
      recover_interrupted(shop)
      processed = 0
      10.times do
        break if shop.api_available_at && shop.api_available_at > Time.current
        order = claim(shop)
        break unless order

        submit(shop, order)
        processed += 1
      end
      processed == 10
    end
    self.class.perform_later(shop_id) if ran
  end

  private

  def recover_interrupted(shop)
    shop.batch_orders.stale.find_each do |order|
      order.with_lock do
        next unless order.status == "running" && order.started_at <= 2.minutes.ago

        mark_review(order, "worker_interrupted")
      end
    end
  end

  def claim(shop)
    candidate = shop.batch_orders.due.joins(:batch).merge(Batch.dispatchable).order(:id).first
    return unless candidate

    batch = candidate.batch
    batch.with_lock do
      candidate.lock!
      next unless batch.confirmed_at && !batch.paused_at && candidate.status == "pending"

      candidate.update!(status: "running", started_at: Time.current, next_attempt_at: nil,
                        attempts: candidate.attempts + 1, error_code: nil)
      batch.audit!("attempt_started", actor: "worker", order: candidate, attempt: candidate.attempts)
      candidate
    end
  end

  def submit(shop, order)
    Rails.logger.tagged("batch=#{order.batch_id}", "order=#{order.id}") do
      begin
        remote = shop.api.create_draft(order)
        order.with_lock do
          order.update_remote!(remote)
          order.batch.audit!("draft_created", actor: "worker", order: order)
        end
      rescue Shopify::Error => error
        order.batch.with_lock do
          order.lock!
          order.batch.audit!("shopify_error", actor: "worker", order: order, code: error.code, request_id: error.request_id)
          case error.kind
          when :retry_later
            defer_or_fail(order, error)
          when :rejected
            order.update!(status: "failed", error_code: error.code)
            if error.code.in?(%w[shopify_permission reconnect_shop])
              order.batch.update!(paused_at: Time.current)
              order.batch.audit!("paused_for_shop_access", actor: "worker", order: order)
            end
          else
            mark_review(order, error.code)
          end
        end
      end
    end
  end

  def defer_or_fail(order, error)
    count = order.throttle_count + 1
    if count >= 8
      order.update!(status: "failed", throttle_count: count, error_code: error.code)
    else
      wait = [error.wait.to_f, 2**count].max
      order.update!(status: "pending", throttle_count: count, error_code: error.code,
                    next_attempt_at: Time.current + wait)
    end
  end

  def mark_review(order, code)
    order.update!(status: "review", error_code: code, sync_at: Time.current)
    order.batch.audit!("needs_reconciliation", actor: "worker", order: order, code: code)
  end
end
