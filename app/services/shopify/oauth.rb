module Shopify
  class OAuth
    SCOPES = %w[read_products read_draft_orders write_draft_orders].freeze
    def self.allowed?(domain)
      Shop::DOMAIN.match?(domain) && ENV.fetch("SHOPIFY_DEV_SHOPS", "").split(",").map(&:strip).include?(domain)
    end

    def self.configured?
      app_uri = URI.parse(ENV.fetch("APP_URL", ""))
      %w[SHOPIFY_CLIENT_ID SHOPIFY_CLIENT_SECRET SECRET_KEY_BASE DATA_ENCRYPTION_KEY].all? { |key| ENV[key].present? } &&
        app_uri.is_a?(URI::HTTPS) && app_uri.host.present? && app_uri.userinfo.nil? &&
        app_uri.path.in?(["", "/"]) && app_uri.query.nil? && app_uri.fragment.nil?
    rescue URI::InvalidURIError
      false
    end

    def self.authorize_url(domain, nonce, online:)
      query = {
        client_id: ENV.fetch("SHOPIFY_CLIENT_ID"), scope: SCOPES.join(","),
        redirect_uri: "#{ENV.fetch("APP_URL").delete_suffix("/")}/auth/shopify/callback", state: nonce
      }
      query["grant_options[]"] = "per-user" if online
      "https://#{domain}/admin/oauth/authorize?#{URI.encode_www_form(query)}"
    end

    def self.valid_callback?(query_string)
      pairs = URI.decode_www_form(query_string)
      return false unless pairs.map(&:first).uniq.size == pairs.size

      signature = pairs.assoc("hmac")&.last.to_s
      message = pairs.reject { |key, _| key == "hmac" }.sort.map { |key, value| "#{key}=#{value}" }.join("&")
      digest = OpenSSL::HMAC.hexdigest("SHA256", ENV.fetch("SHOPIFY_CLIENT_SECRET"), message)
      ActiveSupport::SecurityUtils.secure_compare(digest, signature)
    rescue ArgumentError
      false
    end

    def self.exchange(domain, code, online:)
      parameters = { code: code }
      parameters[:expiring] = 1 unless online
      request_token(domain, parameters)
    end

    def self.refresh(shop)
      raise Error.new("reconnect_shop", kind: :rejected) if shop.refresh_token.blank?
      token = request_token(shop.domain, grant_type: "refresh_token", refresh_token: shop.refresh_token)
      save_token(shop, token)
    end

    def self.save_token(shop, token, **attributes)
      shop.update!(
        access_token: token.fetch("access_token"), refresh_token: token.fetch("refresh_token"),
        token_expires_at: Time.current + Integer(token.fetch("expires_in")), **attributes
      )
    rescue KeyError, ArgumentError
      raise Error.new("invalid_shopify_token_response", kind: :retry_later)
    end

    def self.request_token(domain, parameters)
      body = parameters.merge(
        client_id: ENV.fetch("SHOPIFY_CLIENT_ID"), client_secret: ENV.fetch("SHOPIFY_CLIENT_SECRET")
      )
      response = Transport.post(domain, "/admin/oauth/access_token", body, form: true)
      code = response.code.to_i
      if code == 429 || code >= 500
        raise Error.new("shopify_token_unavailable", kind: :retry_later, wait: 30)
      end
      raise Error.new("reconnect_shop", kind: :rejected) unless code == 200

      JSON.parse(response.body)
    rescue *Transport::NETWORK_ERRORS, JSON::ParserError
      raise Error.new("shopify_token_unavailable", kind: :retry_later, wait: 30)
    end
    private_class_method :request_token
  end
end
