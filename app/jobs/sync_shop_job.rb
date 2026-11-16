class SyncShopJob < ApplicationJob
  def perform(shop_id)
    shop = Shop.find(shop_id)
    shop.with_api_lock do
      shop.batch_orders.sync_due.order(:sync_at, :id).limit(25).each do |order|
        break if shop.api_available_at && shop.api_available_at > Time.current

        reconcile(shop, order)
      end
    end
  end

  private

  def reconcile(shop, order)
    api = shop.api
    begin
      if order.status == "review"
        drafts = api.find_drafts(order.marker)
        apply_match(order, drafts)
      else
        remote = api.draft(order.remote_id)
        refresh_status(order, remote)
      end
    rescue Shopify::Error => error
      Rails.logger.info("shopify_sync batch=#{order.batch_id} order=#{order.id} code=#{error.code}")
      replace_sync_time(order, Time.current + [error.wait.to_f, 60].max)
    end
  end

  def apply_match(order, drafts)
    order.with_lock do
      next unless order.status == "review"

      if drafts&.one? && !BatchOrder.exists?(remote_id: drafts.first.fetch("id"))
        order.update_remote!(drafts.first)
        order.batch.audit!("draft_recovered", actor: "worker", order: order)
      else
        code = drafts&.empty? ? "draft_not_found" : "ambiguous_shopify_match"
        order.update!(error_code: code, sync_at: 10.minutes.from_now)
      end
    end
  end

  def refresh_status(order, remote)
    order.with_lock do
      next unless order.status == "succeeded" && order.remote_status != "DELETED"

      if remote
        order.update_remote!(remote)
        order.update!(sync_at: order.next_sync)
      else
        order.update!(remote_status: "DELETED", sync_at: nil)
        order.batch.audit!("draft_deleted", actor: "worker", order: order)
      end
    end
  end

  def replace_sync_time(order, time)
    order.with_lock do
      order.update!(sync_at: time) if order.status.in?(%w[review succeeded]) && order.sync_at
    end
  end
end
