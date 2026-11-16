class DemoDraft < ApplicationRecord
  belongs_to :shop

  def to_remote
    { "id" => "gid://batchcart-demo/DraftOrder/#{id}", "name" => "#D#{id}", "status" => "OPEN",
      "tags" => [marker], "updatedAt" => updated_at.iso8601(6) }
  end
end
