class ApplicationController < ActionController::Base
  protect_from_forgery with: :exception
  before_action :private_cache

  rescue_from ActiveRecord::RecordNotFound, with: :not_found
  rescue_from BatchImport::Invalid, with: :invalid_input
  rescue_from Shopify::Error, with: :shopify_error
  rescue_from ActionController::InvalidAuthenticityToken do
    render json: { error: "The session expired. Reload BatchCart and try again." }, status: :unprocessable_content
  end

  private

  def current_shop
    return @current_shop if defined?(@current_shop)

    shop = Shop.find_by(id: session[:shop_id])
    @current_shop = shop if shop && shop.session_version == session[:shop_version] &&
      (shop.demo? || (Shopify::OAuth.allowed?(shop.domain) && shop.connected_at.present?))
  end

  def require_shop
    return if current_shop

    render json: { error: "Connect a shop to continue." }, status: :unauthorized
  end

  def actor
    session.fetch(:actor)
  end

  def private_cache
    response.headers["Cache-Control"] = "no-store"
    response.headers["Referrer-Policy"] = "no-referrer"
  end

  def not_found
    render json: { error: "That batch or order could not be found." }, status: :not_found
  end

  def invalid_input(error)
    render json: { error: error.message }, status: :unprocessable_content
  end

  def shopify_error(error)
    if error.kind == :rejected
      render json: { error: "Shopify denied access. Reconnect as the development store owner." }, status: :forbidden
    else
      render json: { error: "Shopify is busy or unavailable. Try again shortly." }, status: :service_unavailable
    end
  end
end
