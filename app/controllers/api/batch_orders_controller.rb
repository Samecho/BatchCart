module Api
  class BatchOrdersController < ApplicationController
    before_action :require_shop
    before_action :load_order

    def retry
      @batch.with_lock do
        @order.lock!
        unless @batch.confirmed_at && @order.status == "failed"
          raise BatchImport::Invalid, "Only a confirmed failure can be retried."
        end

        @order.update!(status: "pending", throttle_count: 0, next_attempt_at: nil, error_code: nil)
        @batch.audit!("retry_queued", actor: actor, order: @order)
      end
      RunShopJob.perform_later(current_shop.id)
      head :no_content
    end

    def reconcile
      @order.with_lock do
        unless @order.status == "review"
          raise BatchImport::Invalid, "This order is no longer waiting for reconciliation."
        end

        @order.update!(sync_at: Time.current)
        @batch.audit!("reconciliation_requested", actor: actor, order: @order)
      end
      SyncShopJob.perform_later(current_shop.id)
      head :no_content
    end

    def close
      @order.with_lock do
        unless @order.status == "review" && params[:acknowledged] == true
          raise BatchImport::Invalid, "Acknowledge the unresolved Shopify result before closing."
        end

        @order.update!(status: "closed", sync_at: nil)
        @batch.audit!("closed_without_match", actor: actor, order: @order)
      end
      head :no_content
    end

    private

    def load_order
      @batch = current_shop.batches.find(params[:batch_id])
      @order = @batch.orders.find(params[:id])
    end
  end
end
