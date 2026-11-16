const csrf = document.querySelector<HTMLMetaElement>('meta[name="csrf-token"]')?.content ?? ""

export class RequestError extends Error {
  constructor(message: string, public status: number) {
    super(message)
  }
}

export async function request<T>(path: string, options: RequestInit = {}): Promise<T> {
  const headers = new Headers(options.headers)
  headers.set("Accept", "application/json")
  headers.set("X-CSRF-Token", csrf)
  if (typeof options.body === "string") headers.set("Content-Type", "application/json")
  const response = await fetch(path, { ...options, headers })
  if (response.status === 204) return undefined as T
  const body = await response.json().catch(() => ({}))
  if (!response.ok) {
    throw new RequestError(body.error ?? "BatchCart could not complete the request. Try again.", response.status)
  }
  return body
}

export function post<T>(path: string, body?: object | FormData) {
  return request<T>(path, {
    method: "POST",
    body: body instanceof FormData ? body : JSON.stringify(body ?? {}),
  })
}
