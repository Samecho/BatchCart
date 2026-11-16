export type Workspace = {
  shop: string | null
  demo: boolean
  demo_available: boolean
  shopify_available: boolean
}

export const fields = [
  ["order_ref", "Order reference"], ["first_name", "First name"], ["last_name", "Last name"],
  ["email", "Email"], ["address1", "Address"], ["address2", "Unit or suite"], ["city", "City"],
  ["province_code", "Province / state"], ["country_code", "Country code"], ["zip", "Postal code"],
  ["sku", "SKU"], ["quantity", "Quantity"],
] as const

export type Field = typeof fields[number][0]
export type Row = Record<Field, string>
export type Issue = { row: number; field: Field; message: string }
export type Order = {
  id: number
  reference: string
  marker: string
  status: string
  attempts: number
  error_code: string | null
  remote_id: string | null
  remote_name: string | null
  remote_status: string | null
  email: string
  address: Record<string, string>
  items: Array<{ id: string; sku: string; title: string; variant: string; quantity: number; row: number }>
}

export type Summary = {
  id: number
  filename: string
  version: number
  created_at: string
  state: string
  counts: Record<string, number>
  issues_count: number
}

export type Batch = Summary & {
  confirmed_at: string | null
  previous_id: number | null
  revision_id: number | null
  rows: Row[]
  issues: Issue[]
  duplicate_references: string[]
  orders: Order[]
  history: Array<{
    batch_order_id: number | null
    action: string
    actor: string
    created_at: string
    details: Record<string, string | number | null>
  }>
}
