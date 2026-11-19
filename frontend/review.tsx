import { useState } from "react"
import { fields, type Batch, type Issue, type Order, type Row } from "./types"
import { post } from "./api"

const labels: Record<string, string> = {
  ready: "Ready to confirm", needs_changes: "Needs changes", superseded: "Superseded",
  processing: "Processing", paused: "Paused", needs_review: "Needs review", finished: "Finished",
  pending: "Pending", running: "Creating", succeeded: "Created", failed: "Failed",
  review: "Needs reconciliation", closed: "Closed unresolved",
}

const errors: Record<string, string> = {
  shopify_throttled: "Shopify rate limit. BatchCart will wait before sending more requests.",
  shopify_rejected_draft: "Shopify rejected the draft. Check the variant and addresses in Shopify.",
  shopify_permission: "Shopify denied access. Reconnect the store before retrying.",
  reconnect_shop: "Reconnect the store before retrying.",
  draft_not_found: "No matching draft found in Shopify yet.",
  ambiguous_shopify_match: "BatchCart could not find a single draft with this order's tag.",
  shopify_transport: "The Shopify request ended without a confirmed result.",
  worker_interrupted: "The worker stopped before it could save the Shopify result.",
}

const fieldLabels = Object.fromEntries(fields)

export function dateTime(raw: string) {
  return new Intl.DateTimeFormat(undefined, { dateStyle: "medium", timeStyle: "short" }).format(new Date(raw))
}

export function Status({ state }: { state: string }) {
  return <span className={`status ${state}`}>{labels[state] ?? state}</span>
}

export function Issues({ issues, onEdit }: { issues: Issue[]; onEdit?: (index: number) => void }) {
  const [expanded, setExpanded] = useState(false)
  if (!issues.length) return null
  return <section className="section" aria-labelledby="validation">
    <h2 id="validation">Validation errors <span className="count">{issues.length}</span></h2>
    <div className="table-wrap"><table>
      <thead><tr><th>CSV record</th><th>Field</th><th>What to fix</th></tr></thead>
      <tbody>{(expanded ? issues : issues.slice(0, 12)).map((issue, index) => <tr key={index}>
        <td>{onEdit ? <button className="text-action" onClick={() => onEdit(issue.row - 2)}>{issue.row}</button> : issue.row}</td>
        <td>{fieldLabels[issue.field]}</td><td>{issue.message}</td>
      </tr>)}</tbody>
    </table></div>
    {issues.length > 12 && <button className="text-action section-action" onClick={() => setExpanded(!expanded)}>
      {expanded ? "Show fewer errors" : "Show all errors"}
    </button>}
  </section>
}

export function RowEditor({
  batch, initialIndex, onCancel, onSave,
}: { batch: Batch; initialIndex: number; onCancel: () => void; onSave: (batch: Batch) => void }) {
  const [rows, setRows] = useState(batch.rows)
  const [index, setIndex] = useState(initialIndex)
  const [error, setError] = useState("")
  const [busy, setBusy] = useState(false)
  const row = rows[index]

  async function save(event: React.FormEvent) {
    event.preventDefault()
    setError("")
    setBusy(true)
    try {
      onSave(await post<Batch>(`/api/batches/${batch.id}/revise`, { rows }))
    } catch (failure) {
      setError((failure as Error).message)
    } finally {
      setBusy(false)
    }
  }

  function addRow() {
    const blank = Object.fromEntries(fields.map(([field]) => [field, ""])) as Row
    setRows([...rows, blank])
    setIndex(rows.length)
  }

  function removeRow() {
    setRows(rows.filter((_, position) => position !== index))
    setIndex(Math.min(index, rows.length - 2))
  }

  return <section className="section editor" aria-labelledby="edit-heading">
    <div className="row-between"><div>
      <h2 id="edit-heading">Edit CSV records</h2>
      <p className="muted">Saving creates version {batch.version + 1} and checks it against the shop’s catalog.</p>
    </div><button onClick={onCancel} disabled={busy}>Cancel</button></div>
    <form onSubmit={save}>
      <fieldset disabled={busy}>
        <div className="editor-nav">
          <label>Record <select value={index} onChange={(event) => setIndex(Number(event.target.value))}>
            {rows.map((entry, position) => <option key={position} value={position}>
              {position + 2}{entry.order_ref ? ` · ${entry.order_ref}` : ""}
            </option>)}
          </select></label>
          <button type="button" disabled={index === 0} onClick={() => setIndex(index - 1)}>Previous</button>
          <button type="button" disabled={index === rows.length - 1} onClick={() => setIndex(index + 1)}>Next</button>
          <button type="button" onClick={addRow} disabled={rows.length >= 1500}>Add record</button>
          <button type="button" onClick={removeRow} disabled={rows.length === 1}>Remove record</button>
        </div>
        <div className="field-grid">
          {fields.map(([field, label]) => <label key={field}>{label}
            <input value={row[field]} onChange={(event) => {
              setRows(rows.map((entry, position) => position === index ? { ...entry, [field]: event.target.value } : entry))
            }} />
          </label>)}
        </div>
      </fieldset>
      {error && <p className="alert error" role="alert">{error}</p>}
      <button className="primary section-action" type="submit" disabled={busy}>{busy ? "Validating…" : "Save and validate"}</button>
    </form>
  </section>
}

function DraftLink({ order, shop }: { order: Order; shop: string }) {
  const id = order.remote_id?.match(/^gid:\/\/shopify\/DraftOrder\/(\d+)$/)?.[1]
  return id ? <a href={`https://${shop}/admin/draft_orders/${id}`} target="_blank" rel="noreferrer">{order.remote_name ?? id}</a>
    : <>{order.remote_name ?? "—"}</>
}

export function Orders({
  batch, shop, action, busy,
}: { batch: Batch; shop: string; action: (path: string, body?: object) => void; busy: boolean }) {
  const [filter, setFilter] = useState("all")
  const [page, setPage] = useState(1)
  const filtered = batch.orders.filter((order) => filter === "all" || order.status === filter)
  const currentPage = Math.min(page, Math.max(1, Math.ceil(filtered.length / 25)))
  const root = `/api/batches/${batch.id}/orders`
  const counts = batch.counts
  const finished = (counts.succeeded ?? 0) + (counts.failed ?? 0) + (counts.review ?? 0) + (counts.closed ?? 0)
  return <section className="section" aria-labelledby="orders-heading">
    <div className="row-between">
      <h2 id="orders-heading">{batch.confirmed_at ? "Orders" : "Order preview"} <span className="count">{batch.orders.length}</span></h2>
      {batch.confirmed_at && <label>Filter <select value={filter} onChange={(event) => { setFilter(event.target.value); setPage(1) }}>
        <option value="all">All orders</option>
        {["pending", "running", "succeeded", "failed", "review", "closed"].map((status) =>
          <option key={status} value={status}>{labels[status]} ({counts[status] ?? 0})</option>)}
      </select></label>}
    </div>
    {batch.confirmed_at && <div className="progress">
      <progress value={finished} max={batch.orders.length} aria-label="Orders with a result" />
      <span>{finished} of {batch.orders.length} with a result · {counts.succeeded ?? 0} created</span>
    </div>}
    {filtered.length ? <div className="table-wrap"><table className="order-table" role="table" aria-labelledby="orders-heading">
      <thead><tr><th>Order</th><th>Recipient</th><th>Items</th>{batch.confirmed_at && <><th>BatchCart</th><th>Shopify</th></>}</tr></thead>
      <tbody role="rowgroup">{filtered.slice((currentPage - 1) * 25, currentPage * 25).map((order) => <tr role="row" key={order.id}>
        <td role="cell" data-label="Order"><strong>{order.reference}</strong>{batch.confirmed_at && <small>
          {order.attempts} {order.attempts === 1 ? "attempt" : "attempts"}
        </small>}</td>
        <td role="cell" data-label="Recipient"><details><summary>{order.address.firstName} {order.address.lastName}</summary>
          <small>{order.address.address1} {order.address.address2}<br />
          {order.address.city}, {order.address.provinceCode} {order.address.zip}<br />{order.address.countryCode}<br />{order.email}</small>
        </details></td>
        <td role="cell" data-label="Items">{order.items.map((item) => <div className="item" key={item.row}>
          <strong>{item.quantity} × {item.title}</strong><small>{item.sku} · {item.variant} · record {item.row}</small>
        </div>)}</td>
        {batch.confirmed_at && <>
          <td role="cell" data-label="BatchCart"><Status state={order.status} />
            {order.error_code && <small>{errors[order.error_code] ?? `Shopify result: ${order.error_code}`}</small>}
            {order.status === "failed" && <button className="text-action" disabled={busy} onClick={() => action(`${root}/${order.id}/retry`)}>Retry</button>}
            {order.status === "review" && <div className="order-actions">
              <button className="text-action" disabled={busy} onClick={() => action(`${root}/${order.id}/reconcile`)}>Check Shopify</button>
              <button className="text-action" disabled={busy} onClick={() => {
                if (window.confirm("Close this item and stop checking for the draft? The Shopify result will remain unresolved.")) {
                  action(`${root}/${order.id}/close`, { acknowledged: true })
                }
              }}>Close unresolved</button>
              <small>Shopify tag <code>{order.marker}</code></small>
            </div>}
          </td>
          <td role="cell" data-label="Shopify"><DraftLink order={order} shop={shop} />{order.remote_status && <small>{order.remote_status.toLowerCase()}</small>}</td>
        </>}
      </tr>)}</tbody>
    </table></div> : <p className="empty">No orders to show.</p>}
    {filtered.length > 25 && <div className="pager">
      <button onClick={() => setPage(currentPage - 1)} disabled={currentPage === 1}>Previous</button>
      <span>Page {currentPage} of {Math.ceil(filtered.length / 25)}</span>
      <button onClick={() => setPage(currentPage + 1)} disabled={currentPage * 25 >= filtered.length}>Next</button>
    </div>}
  </section>
}

export function Activity({ batch }: { batch: Batch }) {
  return <details className="section activity">
    <summary>Activity <span className="count">{batch.history.length}</span></summary>
    <ul>{batch.history.map((event, index) => <li key={index}>
      <time dateTime={event.created_at}>{dateTime(event.created_at)}</time>
      <span>{event.action.replaceAll("_", " ")}{event.batch_order_id ? ` · order ${batch.orders.find((order) => order.id === event.batch_order_id)?.reference ?? event.batch_order_id}` : ""}</span>
      <small>{event.actor}{event.details.code ? ` · ${event.details.code}` : ""}</small>
    </li>)}</ul>
  </details>
}
