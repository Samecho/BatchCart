class ReconcileJob < ApplicationJob
  def perform
    shops = Batch.where(id: BatchOrder.sync_due.select(:batch_id)).select(:shop_id)
    Shop.where(id: shops).find_each { |shop| SyncShopJob.perform_later(shop.id) }
  end
end
