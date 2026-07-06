import { useEffect, useRef, useState } from 'react'
import {
  getDiscover, getWikimedia, getOpenLibrary, getEuropeana,
  getQueueStatus, getQueueProgress, postQueue,
  type DiscoverItem, type DiscoverResponse, type QueueStatus, type ProgressItem,
} from '../api'
import TerminalInput from '../components/TerminalInput'
import { Lamp } from '../components/Lamp'

type Source = 'gutenberg' | 'librivox' | 'archive' | 'loc' | 'wikimedia' | 'openlibrary' | 'europeana'
const SOURCES: { key: Source; label: string }[] = [
  { key: 'gutenberg', label: 'GUTENBERG' },
  { key: 'librivox', label: 'LIBRIVOX' },
  { key: 'archive', label: 'ARCHIVE' },
  { key: 'loc', label: 'LOC' },
  { key: 'wikimedia', label: 'WIKIMEDIA' },
  { key: 'openlibrary', label: 'OPEN LIBRARY' },
  { key: 'europeana', label: 'EUROPEANA' },
]

const PLACEHOLDER: Record<Source, string> = {
  gutenberg: 'browse project gutenberg — 70,000+ titles',
  librivox: 'browse librivox — public-domain audiobooks',
  archive: 'browse the internet archive',
  loc: 'browse the library of congress',
  wikimedia: 'browse wikimedia commons — audio & video',
  openlibrary: 'browse open library — books via internet archive',
  europeana: 'browse europeana — sound & video',
}

const VIEW_LABEL: Partial<Record<Source, string>> = {
  loc: 'VIEW ON LOC.GOV',
  openlibrary: 'VIEW ON OPENLIBRARY',
  europeana: 'VIEW ON EUROPEANA',
}

function mediaTypeFor(source: Source, collection: string, item: DiscoverItem): 'film' | 'music' | 'book' | 'audio' | null {
  if (source === 'gutenberg') return 'book'
  if (source === 'librivox') return 'audio'
  if (source === 'archive') return collection === 'great78' ? 'music' : 'film'
  if (source === 'openlibrary') return 'book'
  if (source === 'wikimedia') return item.mediatype === 'AUDIO' ? 'music' : 'film'
  if (source === 'europeana') return item.type === 'SOUND' ? 'music' : 'film'
  return null
}

export default function Discover() {
  const [source, setSource] = useState<Source>('gutenberg')
  const [collection, setCollection] = useState('films')
  const [wmType, setWmType] = useState('all')
  const [query, setQuery] = useState('')
  const [results, setResults] = useState<DiscoverItem[] | null>(null)
  const [loading, setLoading] = useState(false)
  const [queued, setQueued] = useState<Record<string, 'PENDING' | 'QUEUED' | 'ALREADY_QUEUED' | 'ERROR'>>({})
  const [tooShort, setTooShort] = useState(false)
  const [queue, setQueue] = useState<QueueStatus | null>(null)
  const [progress, setProgress] = useState<ProgressItem[]>([])
  const pollRef = useRef<number | null>(null)
  const progRef = useRef<number | null>(null)

  // poll importer queue status (5s) + download progress (3s) while DISCOVER is mounted
  useEffect(() => {
    let alive = true
    const tick = () => { getQueueStatus().then((s) => { if (alive) setQueue(s) }).catch(() => {}) }
    const tickProg = () => { getQueueProgress().then((p) => { if (alive) setProgress(p.items) }).catch(() => {}) }
    tick(); tickProg()
    pollRef.current = window.setInterval(tick, 5000)
    progRef.current = window.setInterval(tickProg, 3000)
    return () => { alive = false; if (pollRef.current) window.clearInterval(pollRef.current); if (progRef.current) window.clearInterval(progRef.current) }
  }, [])

  async function run() {
    if (query.trim().length < 3) { setTooShort(true); setResults(null); return }
    setTooShort(false)
    setLoading(true)
    setQueued({})
    try {
      const q = query.trim()
      let res: DiscoverResponse
      if (source === 'wikimedia') res = await getWikimedia(q, wmType)
      else if (source === 'openlibrary') res = await getOpenLibrary(q)
      else if (source === 'europeana') res = await getEuropeana(q)
      else res = await getDiscover(source, q, source === 'archive' ? collection : undefined)
      setResults(res.results)
    } catch {
      setResults([])
    } finally {
      setLoading(false)
    }
  }

  function switchSource(s: Source) {
    setSource(s)
    setResults(null)
    setQueued({})
    setTooShort(false)
  }

  async function add(item: DiscoverItem) {
    const mt = mediaTypeFor(source, collection, item)
    if (!mt || !item.download_url) return
    // in-flight marker (honest - NOT a success claim); terminal state set ONLY from the
    // real API response so an auth bounce / failed POST can never read as QUEUED.
    setQueued((q) => ({ ...q, [item.id]: 'PENDING' }))
    try {
      const res = await postQueue({
        source, item_id: item.id, title: item.title,
        download_url: item.download_url, media_type: mt,
      })
      if (res.status === 'ALREADY_QUEUED') {
        setQueued((q) => ({ ...q, [item.id]: 'ALREADY_QUEUED' }))
      } else if (res.status === 'QUEUED') {
        setQueued((q) => ({ ...q, [item.id]: 'QUEUED' }))
      } else {
        setQueued((q) => ({ ...q, [item.id]: 'ERROR' }))
      }
    } catch {
      setQueued((q) => ({ ...q, [item.id]: 'ERROR' }))
    }
  }

  const writable = queue?.importer_writable
  const active = queue?.active ?? []
  const viewLabel = VIEW_LABEL[source] ?? 'VIEW'

  return (
    <>
      <div className="flex-none h-[60px] flex items-center justify-between px-[26px] border-b border-bordermid bg-topbar">
        <div className="flex items-baseline gap-[14px]">
          <div className="font-display text-[24px] tracking-[2px] text-txt">DISCOVER</div>
          <div className="text-[11px] tracking-[1px] text-txt3">// TAKING WHAT'S YOURS TO KEEP</div>
        </div>
        <div className="flex items-center gap-[10px] text-[11px]">
          <Lamp kind={writable ? 'online' : 'offline'} size={8} glow={6} round />
          <span className={writable ? 'text-accent' : 'text-danger'}>
            {writable === undefined ? 'IMPORTER ···' : writable ? 'IMPORTER ONLINE' : 'IMPORTER OFFLINE'}
          </span>
        </div>
      </div>

      <div className="flex-1 overflow-auto px-[26px] py-6">
        {/* source selector */}
        <div className="flex items-start gap-[14px] mb-4">
          <span className="text-[10px] tracking-[2px] text-txt4 mt-2">SOURCE:</span>
          <div className="flex flex-wrap gap-2">
            {SOURCES.map((s) => (
              <button
                key={s.key}
                type="button"
                onClick={() => switchSource(s.key)}
                className={[
                  'px-4 py-2 text-[12px] tracking-[1px]',
                  s.key === source ? 'bg-accent text-ink font-bold' : 'border border-borderstrong text-txt2 hover:text-txt',
                ].join(' ')}
              >
                {s.label}
              </button>
            ))}
          </div>
        </div>

        {/* archive sub-selector */}
        {source === 'archive' && (
          <div className="flex items-center gap-[10px] mb-4">
            <span className="text-[10px] tracking-[2px] text-txt4">COLLECTION:</span>
            {[{ k: 'films', l: 'FILMS' }, { k: 'great78', l: 'GREAT 78' }].map((c) => (
              <button
                key={c.k}
                type="button"
                onClick={() => { setCollection(c.k); setResults(null) }}
                className={[
                  'px-3 py-[6px] text-[11px] tracking-[1px]',
                  collection === c.k ? 'bg-accent text-ink font-bold' : 'border border-borderstrong text-txt2 hover:text-txt',
                ].join(' ')}
              >
                {c.l}
              </button>
            ))}
          </div>
        )}

        {/* wikimedia type sub-selector */}
        {source === 'wikimedia' && (
          <div className="flex items-center gap-[10px] mb-4">
            <span className="text-[10px] tracking-[2px] text-txt4">TYPE:</span>
            {[{ k: 'all', l: 'ALL' }, { k: 'audio', l: 'AUDIO' }, { k: 'video', l: 'VIDEO' }].map((c) => (
              <button
                key={c.k}
                type="button"
                onClick={() => { setWmType(c.k); setResults(null) }}
                className={[
                  'px-3 py-[6px] text-[11px] tracking-[1px]',
                  wmType === c.k ? 'bg-accent text-ink font-bold' : 'border border-borderstrong text-txt2 hover:text-txt',
                ].join(' ')}
              >
                {c.l}
              </button>
            ))}
          </div>
        )}

        <div className="mb-5">
          <TerminalInput value={query} onChange={setQuery} onSubmit={run} placeholder={PLACEHOLDER[source]} />
          {tooShort && (
            <div className="mt-2 text-[11px] tracking-[1px] text-danger">// QUERY TOO SHORT — MINIMUM 3 CHARACTERS</div>
          )}
        </div>

        {loading && (
          <div className="border border-bordermid bg-surface px-[18px] py-[14px] text-[13px] text-loadingdash tracking-[1px]">
            — RAIDING {source.toUpperCase()} —
          </div>
        )}

        {!loading && results && results.length === 0 && (
          <div className="border border-dashed border-borderstrong bg-rail px-[34px] py-[28px] text-center text-[11px] tracking-[1px] text-txt4">
            // NO RESULTS — REFINE QUERY
          </div>
        )}

        {!loading && results && results.length > 0 && (
          <div className="grid grid-cols-2 gap-[14px] mb-6">
            {results.map((item) => {
              const state = queued[item.id]
              const downloadable = !!item.download_url
              const badge = item.format || item.mediatype || item.type || ''
              return (
                <div key={item.id} className="bg-surface border border-bordermid p-4 flex flex-col gap-[10px]">
                  <div className="flex justify-between items-baseline gap-3">
                    <div className="text-[15px] text-txt min-w-0 truncate">{item.title}</div>
                    <span className="text-[10px] text-txt3 whitespace-nowrap">{badge}</span>
                  </div>
                  <div className="text-[11px] text-txt2 leading-[1.5] line-clamp-2">
                    {item.author || item.creator || ''}
                    {item.year ? ` — ${item.year}` : item.date ? ` — ${item.date}` : ''}
                    {item.duration ? ` · ${item.duration}` : ''}
                    {item.chapters ? ` · ${item.chapters} ch` : ''}
                    {item.mime ? ` · ${item.mime}` : ''}
                    {item.size_bytes ? ` · ${(item.size_bytes / 1048576).toFixed(1)}MB` : ''}
                  </div>
                  {item.description && (
                    <div className="text-[11px] text-txt4 leading-[1.5] line-clamp-2">{item.description}</div>
                  )}
                  <div className="mt-1">
                    {!downloadable ? (
                      <a
                        href={item.landing_url}
                        target="_blank"
                        rel="noopener noreferrer"
                        className="inline-block border border-borderstrong text-txt2 text-[12px] tracking-[1px] px-4 py-2 hover:text-txt no-underline"
                      >
                        {viewLabel} ↗
                      </a>
                    ) : state === 'PENDING' ? (
                      <div className="inline-flex items-center gap-2 border border-borderstrong text-txt2 font-display text-[12px] tracking-[1px] px-4 py-2">
                        QUEUING…
                      </div>
                    ) : state === 'QUEUED' || state === 'ALREADY_QUEUED' ? (
                      <div className="inline-flex items-center gap-2 border border-accent text-accent font-display text-[12px] tracking-[1px] px-4 py-2">
                        {state === 'ALREADY_QUEUED' ? 'ALREADY QUEUED' : '✓ QUEUED'}
                      </div>
                    ) : state === 'ERROR' ? (
                      <button
                        type="button"
                        onClick={() => add(item)}
                        className="border border-danger text-danger font-display text-[12px] tracking-[1px] px-4 py-2 hover:bg-danger hover:text-ink transition-colors"
                      >
                        ⚠ FAILED — RETRY
                      </button>
                    ) : (
                      <button
                        type="button"
                        onClick={() => add(item)}
                        className="bg-accent text-ink font-display text-[12px] tracking-[1px] px-4 py-2 hover:bg-white transition-colors"
                      >
                        + ADD TO VAULT
                      </button>
                    )}
                  </div>
                </div>
              )
            })}
          </div>
        )}

        {/* importer queue panel */}
        <div className="border border-bordermid bg-surface">
          <div className="px-[18px] py-3 border-b border-bordermid font-display text-[12px] tracking-[2px] text-txt2">
            IMPORTER QUEUE — {active.length} ACTIVE
          </div>
          {active.length === 0 ? (
            <div className="px-[18px] py-3 text-[11px] text-txt4 tracking-[1px]">// IDLE — NO ITEMS PROCESSING</div>
          ) : (
            active.map((a, i) => (
              <div key={i} className="grid grid-cols-[110px_1fr_120px] gap-[14px] items-center px-[18px] py-3 border-b border-hair last:border-b-0 text-[12px]">
                <span className="text-[10px] tracking-[1px] text-accent">[{a.share.toUpperCase()}]</span>
                <span className="text-txt truncate">{a.file || '—'}</span>
                <span className="text-right text-txt2 tracking-[1px]">{a.status}</span>
              </div>
            ))
          )}
          {progress.length > 0 && (
            <>
              <div className="px-[18px] py-3 border-t border-bordermid border-b border-bordermid font-display text-[12px] tracking-[2px] text-txt2">DOWNLOADS — {progress.length}</div>
              {progress.map((p) => (
                <div key={p.item_id} className="grid grid-cols-[1fr_160px_92px] gap-[14px] items-center px-[18px] py-3 border-b border-hair last:border-b-0 text-[12px]">
                  <span className="text-txt truncate">{p.title}</span>
                  <div className="h-[8px] bg-surfacealt border border-bordermid overflow-hidden">
                    <div className="gauge-fill h-full" style={{ width: `${p.pct ?? 100}%` }} />
                  </div>
                  <span className={['text-right tracking-[1px]', p.status === 'error' ? 'text-danger' : p.status === 'complete' ? 'text-txt' : 'text-accent'].join(' ')}>
                    {p.status === 'complete' ? '✓ COMPLETE' : p.status === 'error' ? '✗ ERROR' : (p.pct != null ? `${p.pct}%` : `${(p.bytes_received / 1048576).toFixed(1)}MB`)}
                  </span>
                </div>
              ))}
            </>
          )}
        </div>
      </div>
    </>
  )
}
