// Typed client for the wizard /api layer. Relative URLs -> same origin.
export type Health = Record<string, 'ONLINE' | 'OFFLINE'>

export interface Stats {
  films: number | null
  albums: number | null
  books: number | null
  audiobooks: number | null
  photos: number | null
}

export interface System {
  cpu_pct: number
  ram_pct: number
  disk_used_bytes: number
  disk_total_bytes: number
  disk_pct: number
  uptime_seconds: number
}

export interface RecentItem {
  type: 'FILM' | 'MUSIC' | 'BOOK' | 'AUDIO' | 'PHOTO'
  title: string
  added: string
}

export interface Me { username: string }

async function j<T>(path: string): Promise<T> {
  const r = await fetch(path, { headers: { Accept: 'application/json' } })
  if (!r.ok) throw new Error(`${path} -> ${r.status}`)
  return (await r.json()) as T
}

export const getHealth = () => j<Health>('/api/health')
export const getStats = () => j<Stats>('/api/stats')
export const getSystem = () => j<System>('/api/system')
export const getRecent = () => j<RecentItem[]>('/api/recent')
export const getMe = () => j<Me>('/api/me')

// ---- Phase 2: VAULT ----
export interface SearchResult {
  type: 'FILM' | 'MUSIC' | 'BOOK' | 'AUDIO' | 'PHOTO'
  title: string
  subtitle: string
  service: string
  deep_link: string
}
export interface SearchResponse {
  results: SearchResult[]
  total: number
  query: string
  type: string
  responded: number
}
export const getSearch = (q: string, type: string) =>
  j<SearchResponse>(`/api/search?q=${encodeURIComponent(q)}&type=${encodeURIComponent(type)}`)

// ---- Phase 2: DISCOVER ----
export interface DiscoverItem {
  id: string
  title: string
  author?: string
  creator?: string
  date?: string
  description?: string
  format?: string | null
  size_bytes?: number | null
  duration?: string
  chapters?: number
  mediatype?: 'AUDIO' | 'VIDEO'
  mime?: string | null
  type?: 'SOUND' | 'VIDEO'
  year?: number | string | null
  download_url: string | null
  landing_url?: string
}
export interface DiscoverResponse {
  results: DiscoverItem[]
  source: string
  collection?: string
}
export const getDiscover = (source: string, q: string, collection?: string) =>
  j<DiscoverResponse>(
    `/api/discover/${source}?q=${encodeURIComponent(q)}` +
      (collection ? `&collection=${encodeURIComponent(collection)}` : ''),
  )

export interface QueueItem { share: string; file: string; status: string; progress: string }
export interface QueueStatus { active: QueueItem[]; importer_writable: boolean }
export const getQueueStatus = () => j<QueueStatus>('/api/queue/status')

export interface QueueBody {
  source: string
  item_id: string
  title: string
  download_url: string
  media_type: 'film' | 'music' | 'book' | 'audio'
}
export interface QueueResult { status: string; item_id: string; title: string }
export async function postQueue(body: QueueBody): Promise<QueueResult> {
  // redirect:'error' -> an Authelia/proxy auth bounce (POST -> 302/303) is a HARD
  // failure, never silently followed to an HTML 200 that would masquerade as success.
  const r = await fetch('/api/queue', {
    method: 'POST',
    headers: { 'Content-Type': 'application/json', Accept: 'application/json' },
    body: JSON.stringify(body),
    redirect: 'error',
  })
  if (!r.ok) {
    const err = (await r.json().catch(() => ({}))) as { error?: string }
    throw new Error(err.error || `queue -> ${r.status}`)
  }
  const ct = r.headers.get('content-type') || ''
  if (!ct.includes('application/json')) {
    throw new Error('queue: non-JSON response (not authenticated / wrong endpoint)')
  }
  const data = (await r.json()) as QueueResult
  if (!data || typeof data.status !== 'string') {
    throw new Error('queue: malformed response')
  }
  return data
}


// ---- Phase 3: USERS ----
export interface MeInfo { username: string; is_admin: boolean; must_change_password: boolean }
export const getMeFull = () => j<MeInfo>('/api/me')

export interface UserRow {
  username: string
  displayname: string
  email: string
  groups: string[]
  disabled: boolean
  must_change_password: boolean
  undeletable: boolean
  app_access: Record<'jellyfin' | 'navidrome' | 'kavita' | 'abs' | 'immich', boolean | null>
}
export const getUsers = () => j<{ users: UserRow[] }>('/api/users')

export interface PropReport { service: string; ok: boolean | null; detail: string }
export interface UserOpResult { username: string; propagation?: PropReport[]; error?: string }

async function jsonReq<T>(method: string, path: string, body?: unknown): Promise<{ status: number; data: T }> {
  const r = await fetch(path, {
    method,
    headers: { 'Content-Type': 'application/json', Accept: 'application/json' },
    body: body === undefined ? undefined : JSON.stringify(body),
    redirect: 'error',
  })
  const ct = r.headers.get('content-type') || ''
  if (!ct.includes('application/json')) throw new Error('unexpected non-JSON response (not authenticated?)')
  const data = (await r.json()) as T
  if (!r.ok && r.status !== 207) {
    throw Object.assign(new Error((data as { error?: string }).error || `${path} -> ${r.status}`), { status: r.status })
  }
  return { status: r.status, data }
}

export const createUser = (b: { username: string; displayname: string; email: string; password: string; is_admin: boolean }) =>
  jsonReq<UserOpResult>('POST', '/api/users', b)
export const deleteUser = (username: string) =>
  jsonReq<UserOpResult>('DELETE', `/api/users/${encodeURIComponent(username)}`)
export const changePassword = (username: string, b: { current_password?: string; new_password: string }) =>
  jsonReq<UserOpResult>('POST', `/api/users/${encodeURIComponent(username)}/change-password`, b)

// ---- Agent 10: first-run setup ----
export interface SetupStatus { complete: boolean }
export const getSetupStatus = () => j<SetupStatus>('/api/setup/status')

export interface StorageCheck {
  ok: boolean
  writable: boolean
  free_gb: number
  warn: boolean
  min_gb: number
  message: string
}
export const validateStorage = (path: string) =>
  jsonReq<StorageCheck>('POST', '/api/setup/validate-storage', { path })

export const configureLocalTls = () =>
  jsonReq<{ ok: boolean; note?: string }>('POST', '/api/setup/configure-local-tls', {})
export const configureDomainTls = (b: { domain: string; dns_provider: string; dns_api_key: string }) =>
  jsonReq<{ ok: boolean; domain?: string }>('POST', '/api/setup/configure-domain-tls', b)

export interface PropRow { ok: boolean; app?: string; name?: string; service?: string; detail?: string }
export const createAdmin = (b: { username: string; password: string; email: string }) =>
  jsonReq<{ ok: boolean; username?: string; propagation?: PropRow[] }>('POST', '/api/setup/create-admin', b)

export const configureModules = (b: { modules: string[]; nordvpn_token?: string }) =>
  jsonReq<{ ok: boolean; modules?: string[] }>('POST', '/api/setup/configure-modules', b)

export interface TotpEnroll { secret: string; otpauth_uri: string; issuer: string }
export const totpEnroll = (username: string) =>
  j<TotpEnroll>(`/api/setup/totp-enroll?username=${encodeURIComponent(username)}`)
export const verifyTotp = (b: { secret: string; code: string }) =>
  jsonReq<{ ok: boolean; error?: string | null }>('POST', '/api/setup/verify-totp', b)

export const completeSetup = () =>
  jsonReq<{ ok: boolean; complete?: boolean }>('POST', '/api/setup/complete', {})


// ---- Phase 3 polish: download progress ----
export interface ProgressItem {
  item_id: string
  title: string
  bytes_received: number
  total_bytes: number | null
  pct: number | null
  status: 'downloading' | 'complete' | 'error'
}
export const getQueueProgress = () => j<{ items: ProgressItem[] }>('/api/queue/progress')


// ---- Ep4 Pass 2: Wikimedia / Open Library / Europeana ----
export const getWikimedia = (q: string, type: string) =>
  j<DiscoverResponse>(`/api/discover/wikimedia?q=${encodeURIComponent(q)}&type=${encodeURIComponent(type)}`)
export const getOpenLibrary = (q: string) =>
  j<DiscoverResponse>(`/api/discover/openlibrary?q=${encodeURIComponent(q)}`)
export const getEuropeana = (q: string) =>
  j<DiscoverResponse>(`/api/discover/europeana?q=${encodeURIComponent(q)}`)
