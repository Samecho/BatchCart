module Shopify
  class Error < StandardError
    attr_reader :code, :kind, :wait, :request_id

    def initialize(code, kind:, wait: nil, request_id: nil)
      super(code)
      @code, @kind, @wait, @request_id = code, kind, wait, request_id
    end
  end
end
