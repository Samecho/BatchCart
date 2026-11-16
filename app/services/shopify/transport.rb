require "net/http"

module Shopify
  class Transport
    def self.post(domain, path, body, headers = {}, form: false)
      raise ArgumentError, "Invalid Shopify domain" unless Shop::DOMAIN.match?(domain)

      uri = URI::HTTPS.build(host: domain, path: path)
      request = Net::HTTP::Post.new(uri, { "Accept" => "application/json" }.merge(headers))
      if form
        request.set_form_data(body)
      else
        request.content_type = "application/json"
        request.body = JSON.generate(body)
      end
      Net::HTTP.start(uri.host, uri.port, nil, use_ssl: true, open_timeout: 4,
                      read_timeout: 10, write_timeout: 5, max_retries: 0) do |http|
        http.request(request)
      end
    end

    NETWORK_ERRORS = [Timeout::Error, IOError, SocketError, SystemCallError, OpenSSL::SSL::SSLError].freeze
  end
end
