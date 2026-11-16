demo = ENV["BATCHCART_DEMO"] == "1"
if demo && Rails.env.production?
  raise "Demo mode is only available in development and test"
end

key = ENV["DATA_ENCRYPTION_KEY"]
if key.blank?
  if !demo && !Rails.env.test? && ENV["SHOPIFY_CLIENT_ID"].present?
    raise "Set DATA_ENCRYPTION_KEY before connecting Shopify"
  end
  key = "local-batchcart-development-key"
end
encryption = Rails.application.config.active_record.encryption
encryption.primary_key = OpenSSL::HMAC.hexdigest("SHA256", key, "primary")
encryption.key_derivation_salt = OpenSSL::HMAC.hexdigest("SHA256", key, "salt")
