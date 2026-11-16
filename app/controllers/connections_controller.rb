class ConnectionsController < ApplicationController
  def create
    domain = params[:shop].to_s.strip.downcase
    unless Shopify::OAuth.configured? && Shopify::OAuth.allowed?(domain)
      return render json: { error: "Enter an allowed development store's .myshopify.com domain." }, status: :unprocessable_content
    end

    url = begin_grant(domain, online: true)
    render json: { url: url }
  end

  def callback
    return head :bad_request unless Shopify::OAuth.configured? && Shopify::OAuth.valid_callback?(request.query_string)

    grant = session.delete(:shopify_grant)
    query = request.query_parameters
    domain = query["shop"].to_s
    unless grant && Shopify::OAuth.allowed?(domain) && domain == grant["shop"] &&
        grant["expires"] >= Time.current.to_i &&
        ActiveSupport::SecurityUtils.secure_compare(grant["nonce"], query["state"].to_s) &&
        query["timestamp"].to_i.between?(10.minutes.ago.to_i, 1.minute.from_now.to_i) &&
        query["code"].present?
      return head :bad_request
    end

    if grant["online"]
      authorize_owner(domain, query["code"])
    else
      connect(domain, query["code"], grant.fetch("actor"))
    end
  end

  def demo
    return head :not_found unless ENV["BATCHCART_DEMO"] == "1"

    shop = Shop.find_or_create_by!(domain: Shop::DEMO_DOMAIN)
    start_session(shop, "demo")
    head :no_content
  end

  def destroy
    reset_session
    head :no_content
  end

  private

  def begin_grant(domain, online:, actor: nil)
    nonce = SecureRandom.hex(32)
    session[:shopify_grant] = {
      "shop" => domain, "online" => online, "nonce" => nonce, "actor" => actor,
      "expires" => 10.minutes.from_now.to_i
    }
    Shopify::OAuth.authorize_url(domain, nonce, online: online)
  end

  def authorize_owner(domain, code)
    token = Shopify::OAuth.exchange(domain, code, online: true)
    user = token.fetch("associated_user", {})
    unless user["account_owner"] == true && user["id"].present? && scopes_granted?(token["associated_user_scope"])
      return render plain: "Connect BatchCart as the development store owner with access to products and draft orders.",
                    status: :forbidden
    end

    redirect_to begin_grant(domain, online: false, actor: "shopify:#{user['id']}"), allow_other_host: true
  end

  def connect(domain, code, actor)
    shop = Shop.find_or_create_by!(domain: domain)
    connected = shop.with_api_lock do
      token = Shopify::OAuth.exchange(domain, code, online: false)
      unless scopes_granted?(token["scope"])
        raise Shopify::Error.new("shopify_permission", kind: :rejected)
      end

      shop.with_lock do
        Shopify::OAuth.save_token(shop, token, connected_at: Time.current, api_available_at: nil,
                                 session_version: shop.session_version + 1)
      end
    end
    return render plain: "The shop is busy. Open BatchCart and reconnect.", status: :service_unavailable unless connected

    start_session(shop, actor)
    redirect_to root_path
  end

  def scopes_granted?(scopes)
    granted = scopes.to_s.split(",").map(&:strip)
    granted += granted.grep(/\Awrite_/).map { |scope| scope.sub(/\Awrite_/, "read_") }
    (Shopify::OAuth::SCOPES - granted).empty?
  end

  def start_session(shop, actor)
    reset_session
    session[:shop_id] = shop.id
    session[:shop_version] = shop.session_version
    session[:actor] = actor
  end
end
