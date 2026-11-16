class WorkspaceController < ApplicationController
  def show
    @workspace = {
      shop: current_shop&.domain, demo: current_shop&.demo? || false,
      demo_available: ENV["BATCHCART_DEMO"] == "1",
      shopify_available: Shopify::OAuth.configured?
    }
    render :show
  end
end
