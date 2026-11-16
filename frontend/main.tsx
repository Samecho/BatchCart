import { useEffect, useState } from "react"
import { createRoot } from "react-dom/client"
import { post, request, RequestError } from "./api"
import { Activity, dateTime, Issues, Orders, RowEditor, Status } from "./review"
import type { Batch, Summary, Workspace } from "./types"
import "./style.css"

function Connect({ workspace }: { workspace: Workspace }) {
  const [domain, setDomain] = useState("")
  const [busy, setBusy] = useState(false)
  const [error, setError] = useState("")

  async function connect(demo = false) {
    setError("")
    setBusy(true)
    try {
      if (demo) {
        await post("/auth/demo")
        window.location.assign("/")
      } else {
        const result = await post<{ url: string }>("/auth/shopify", { shop: domain })
        window.location.assign(result.url)
      }
    } catch (failure) {
      setError((failure as Error).message)
      setBusy(false)
    }
  }

  return <main className="connection">
    <h1>Connect your shop</h1>
    <p className="description">Turn a spreadsheet of recipients and SKUs into Shopify draft orders.</p>
    {workspace.shopify_available && <form onSubmit={(event) => { event.preventDefault(); void connect() }}>
      <label>Shop domain <input required name="shop" placeholder="your-store.myshopify.com" value={domain}
        onChange={(event) => setDomain(event.target.value)} autoCapitalize="none" spellCheck={false} /></label>
      <button className="primary" disabled={busy}>Continue to Shopify</button>
    </form>}
    {workspace.demo_available && <button className="primary" disabled={busy} onClick={() => connect(true)}>Open demo shop</button>}
    {!workspace.shopify_available && !workspace.demo_available && <p className="alert">Shopify connection is awaiting configuration.</p>}
    {error && <p className="alert error" role="alert">{error}</p>}
  </main>
}

function BatchList({ open }: { open: (batch: Batch) => void }) {
  const [page, setPage] = useState(1)
  const [results, setResults] = useState<{ batches: Summary[]; more: boolean }>()
  const [file, setFile] = useState<File | null>(null)
  const [busy, setBusy] = useState(false)
  const [error, setError] = useState("")

  useEffect(() => {
    const controller = new AbortController()
    request<{ batches: Summary[]; more: boolean }>(`/api/batches?page=${page}`, { signal: controller.signal })
      .then(setResults).catch((failure) => { if (!controller.signal.aborted) setError(failure.message) })
    return () => controller.abort()
  }, [page])

  async function upload(event: React.FormEvent) {
    event.preventDefault()
    if (!file) return
    setError("")
    setBusy(true)
    try {
      const form = new FormData()
      form.set("file", file)
      open(await post<Batch>("/api/batches", form))
    } catch (failure) {
      setError((failure as Error).message)
    } finally {
      setBusy(false)
    }
  }

  return <main>
    <div className="heading row-between">
      <div><h1>Order batches</h1><p className="description">Import a CSV, review the recipients, and create draft orders in Shopify.</p></div>
      <a className="button" href="/order-template.csv" download>Download CSV template</a>
    </div>
    <form className="upload" onSubmit={upload}>
      <div><h2>Import orders</h2><p>Use one row per SKU. Rows with the same order reference go into one draft.</p></div>
      <div className="row-between upload-controls">
        <input id="order-csv" type="file" accept=".csv,text/csv" aria-label="Order CSV"
          onChange={(event) => setFile(event.target.files?.[0] ?? null)} disabled={busy} />
        <button type="submit" className="primary" disabled={!file || busy}>{busy ? "Validating…" : "Upload and validate"}</button>
      </div>
    </form>
    {error && <p className="alert error" role="alert">{error}</p>}
    <section className="section">
      <h2>Import history</h2>
      {!results ? <p className="empty">Loading batches…</p> : results.batches.length ?
        <div className="table-wrap"><table>
          <thead><tr><th>File</th><th>Imported</th><th>Orders</th><th>Status</th></tr></thead>
          <tbody>{results.batches.map((batch) => <tr key={batch.id}>
            <td><a href={`/batches/${batch.id}`}>{batch.filename}</a><small>Version {batch.version}</small></td>
            <td>{dateTime(batch.created_at)}</td>
            <td>{Object.values(batch.counts).reduce((total, count) => total + count, 0)}</td>
            <td><Status state={batch.state} /></td>
          </tr>)}</tbody>
        </table></div> : <p className="empty">No batches yet. Upload a CSV to get started.</p>}
      {(page > 1 || results?.more) && <div className="pager">
        <button onClick={() => setPage(page - 1)} disabled={page === 1}>Previous</button>
        <span>Page {page}</span>
        <button onClick={() => setPage(page + 1)} disabled={!results?.more}>Next</button>
      </div>}
    </section>
  </main>
}

function BatchDetail({
  id, initial, shop, open,
}: { id: number; initial: Batch | null; shop: string; open: (batch: Batch) => void }) {
  const [batch, setBatch] = useState(initial)
  const [edit, setEdit] = useState<number | null>(null)
  const [acknowledged, setAcknowledged] = useState(false)
  const [busy, setBusy] = useState(false)
  const [error, setError] = useState("")
  const path = `/api/batches/${id}`
  const poll = batch?.confirmed_at && edit === null && !busy
  const pollMs = batch?.state === "processing" ? 2000 : 6000

  useEffect(() => {
    if (initial) return
    const controller = new AbortController()
    request<Batch>(path, { signal: controller.signal }).then(setBatch)
      .catch((failure) => { if (!controller.signal.aborted) setError(failure.message) })
    return () => controller.abort()
  }, [path, initial])

  useEffect(() => {
    if (!poll) return
    let active = true
    let timer = 0
    const controller = new AbortController()
    const refresh = async () => {
      try {
        const result = await request<Batch>(path, { signal: controller.signal })
        if (active) setBatch(result)
      } catch (failure) {
        if (active) setError((failure as Error).message)
      } finally {
        if (active) timer = window.setTimeout(refresh, pollMs)
      }
    }
    timer = window.setTimeout(refresh, pollMs)
    return () => { active = false; window.clearTimeout(timer); controller.abort() }
  }, [poll, pollMs, path])

  async function action(endpoint: string, payload?: object) {
    setBusy(true)
    setError("")
    try {
      const updated = await post<Batch | undefined>(endpoint, payload)
      setBatch(updated ?? await request<Batch>(path))
    } catch (failure) {
      setError((failure as Error).message)
      if (failure instanceof RequestError && failure.status === 409) {
        setAcknowledged(false)
        const updated = await request<Batch>(path).catch(() => null)
        if (updated) setBatch(updated)
      }
    } finally {
      setBusy(false)
    }
  }

  if (!batch) return <main><a className="back" href="/">← Order batches</a>
    {error ? <p className="alert error" role="alert">{error}</p> : <p className="empty">Loading batch…</p>}
  </main>

  const duplicates = batch.duplicate_references
  const canEdit = !batch.revision_id && batch.state !== "superseded"
  return <main>
    <a className="back" href="/">← Order batches</a>
    <div className="heading row-between">
      <div>
        <div className="title-line"><h1>{batch.filename}</h1><Status state={batch.state} /></div>
        <p className="description">Version {batch.version} · {batch.rows.length} CSV records · {dateTime(batch.created_at)}</p>
      </div>
      <div className="actions">
        {canEdit && edit === null && <button onClick={() => setEdit(0)} disabled={busy}>
          {batch.confirmed_at ? "Create revision" : "Edit records"}
        </button>}
        {batch.confirmed_at && <a className="button" href={`${path}/export`}>Export results</a>}
        {batch.state === "processing" && <button disabled={busy} onClick={() => action(`${path}/pause`)}>Pause</button>}
        {batch.state === "paused" && <button disabled={busy} onClick={() => action(`${path}/resume`)}>Resume</button>}
      </div>
    </div>
    {(batch.previous_id || batch.revision_id) && <nav className="version-links" aria-label="Batch versions">
      {batch.previous_id && <a href={`/batches/${batch.previous_id}`}>Previous version</a>}
      {batch.revision_id && <a href={`/batches/${batch.revision_id}`}>Next version</a>}
    </nav>}
    {error && <p className="alert error" role="alert">{error}</p>}
    {batch.state === "paused" && <p className="alert">New drafts are paused. A request already sent to Shopify may finish.</p>}
    {edit !== null && <RowEditor key={edit} batch={batch} initialIndex={edit} onCancel={() => setEdit(null)} onSave={open} />}
    <Issues issues={batch.issues} onEdit={canEdit && edit === null ? setEdit : undefined} />
    <Orders batch={batch} shop={shop} action={action} busy={busy} />
    {batch.state === "ready" && edit === null && <section className="section confirm">
      {duplicates.length > 0 && <div className="alert warning">
        <strong>Possible duplicate orders ({duplicates.length})</strong>
        <p>{duplicates.join(", ")}</p>
        <label><input type="checkbox" checked={acknowledged} onChange={(event) => setAcknowledged(event.target.checked)} />
          Create these orders again
        </label>
      </div>}
      <div className="row-between">
        <p>Confirming locks this version and queues its draft orders.</p>
        <button className="primary" onClick={() => action(`${path}/confirm`, {
          duplicate_references: acknowledged ? duplicates : [],
        })} disabled={busy || (duplicates.length > 0 && !acknowledged)}>
          {busy ? "Confirming…" : `Create ${batch.orders.length} draft order${batch.orders.length === 1 ? "" : "s"}`}
        </button>
      </div>
    </section>}
    <Activity batch={batch} />
  </main>
}

function pathBatchId() {
  const match = window.location.pathname.match(/^\/batches\/(\d+)$/)
  return match ? Number(match[1]) : null
}

function App({ workspace }: { workspace: Workspace }) {
  const [selection, setSelection] = useState<{ id: number | null; initial: Batch | null }>({
    id: pathBatchId(), initial: null,
  })
  const [sessionError, setSessionError] = useState("")
  useEffect(() => {
    const onPop = () => setSelection({ id: pathBatchId(), initial: null })
    window.addEventListener("popstate", onPop)
    return () => window.removeEventListener("popstate", onPop)
  }, [])

  function open(batch: Batch) {
    window.history.pushState({}, "", `/batches/${batch.id}`)
    setSelection({ id: batch.id, initial: batch })
    window.scrollTo(0, 0)
  }

  async function signOut() {
    try {
      await request("/session", { method: "DELETE" })
      window.location.assign("/")
    } catch (failure) {
      setSessionError((failure as Error).message)
    }
  }

  return <>
    <header className="topbar"><div>
      <a className="brand" href="/" aria-label="BatchCart home"><span className="brand-mark" aria-hidden="true"><i /><i /><i /></span>BatchCart</a>
      {workspace.shop && <div className="shop"><span>{workspace.demo ? "Demo shop" : workspace.shop}</span>
        <button className="text-action" onClick={signOut}>Sign out</button></div>}
    </div></header>
    {sessionError && <p className="alert error session-error" role="alert">{sessionError}</p>}
    {!workspace.shop ? <Connect workspace={workspace} /> : selection.id ?
      <BatchDetail key={selection.id} id={selection.id} initial={selection.initial} shop={workspace.shop} open={open} /> :
      <BatchList open={open} />}
  </>
}

const root = document.getElementById("app")!
createRoot(root).render(<App workspace={JSON.parse(root.dataset.workspace!)} />)
