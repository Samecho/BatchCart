class DispatchJob < ApplicationJob
  def perform
    pending = Batch.dispatchable.where(id: BatchOrder.due.select(:batch_id)).select(:shop_id)
    stale = Batch.where(id: BatchOrder.stale.select(:batch_id)).select(:shop_id)
    Shop.where(id: pending).or(Shop.where(id: stale)).find_each do |shop|
      RunShopJob.perform_later(shop.id)
    end
  end
end
