import { useState } from 'react'
import { getSearch, type SearchResult } from '../api'
import TerminalInput from '../components/TerminalInput'

const TABS = [
  { label: 'ALL', type: 'all' },
  { label: 'FILMS', type: 'film' },
  { label: 'MUSIC', type: 'music' },
  { label: 'BOOKS', type: 'book' },
  { label: 'AUDIOBOOKS', type: 'audio' },
  { label: 'PHOTOS', type: 'photo' },
] as const

export default function Vault() {
  const [query, setQuery] = useState('')
  const [tab, setTab] = useState('all')
  const [results, setResults] = useState<SearchResult[] | null>(null)
  const [loading, setLoading] = useState(false)
  const [responded, setResponded] = useState(0)
  const [tooShort, setTooShort] = useState(false)
  const [submitted, setSubmitted] = useState('')

  async function run(q: string, type: string) {
    if (q.trim().length < 3) {
      setTooShort(true)
      setResults(null)
      return
    }
    setTooShort(false)
    setLoading(true)
    setSubmitted(q.trim())
    try {
      const res = await getSearch(q.trim(), type)
      setResults(res.results)
      setResponded(res.responded)
    } catch {
      setResults([])
      setResponded(0)
    } finally {
      setLoading(false)
    }
  }

  function onTab(type: string) {
    setTab(type)
    if (submitted) run(submitted, type)
  }

  const allOffline = results !== null && results.length === 0 && responded === 0 && !loading
  const emptyMatch = results !== null && results.length === 0 && responded > 0 && !loading

  return (
    <>
      <div className="flex-none h-[60px] flex items-center justify-between px-[26px] border-b border-bordermid bg-topbar">
        <div className="flex items-baseline gap-[14px]">
          <div className="font-display text-[24px] tracking-[2px] text-txt">VAULT</div>
          <div className="text-[11px] tracking-[1px] text-txt3">// INTERROGATE THE DATABASE</div>
        </div>
        <div className="text-[11px] text-txt2">
          {results ? `${results.length} MATCHES / ${responded} SERVICES` : 'STANDBY'}
        </div>
      </div>

      <div className="flex-1 overflow-auto px-[26px] py-6">
        <div className="mb-4">
          <TerminalInput value={query} onChange={setQuery} onSubmit={() => run(query, tab)} placeholder="search the vault" />
          {tooShort && (
            <div className="mt-2 text-[11px] tracking-[1px] text-danger">// QUERY TOO SHORT — MINIMUM 3 CHARACTERS</div>
          )}
        </div>

        <div className="flex border border-bordermid mb-[18px]">
          {TABS.map((t, i) => {
            const on = t.type === tab
            return (
              <button
                key={t.type}
                type="button"
                onClick={() => onTab(t.type)}
                className={[
                  'flex-1 text-center py-[9px] text-[11px] tracking-[2px]',
                  i > 0 ? 'border-l border-bordermid' : '',
                  on ? 'bg-accent text-ink font-bold' : 'text-txt2 hover:text-txt',
                ].join(' ')}
              >
                {t.label}
              </button>
            )
          })}
        </div>

        {loading && (
          <div className="border border-bordermid bg-surface px-[18px] py-[14px] text-[13px] text-loadingdash tracking-[1px]">
            — SEARCHING FIVE SERVICES —
          </div>
        )}

        {!loading && results && results.length > 0 && (
          <div className="border border-bordermid bg-surface">
            {results.map((r, idx) => (
              <button
                key={idx}
                type="button"
                onClick={() => window.open(r.deep_link, '_blank', 'noopener,noreferrer')}
                className="w-full text-left grid grid-cols-[96px_1fr_150px] gap-[14px] items-center px-[18px] py-[14px] border-b border-hair last:border-b-0 hover:bg-bordermid/30 transition-colors"
              >
                <span className="text-[10px] tracking-[1px] text-accent">[{r.type}]</span>
                <span className="min-w-0">
                  <span className="block text-[14px] text-txt truncate">{r.title}</span>
                  {r.subtitle && <span className="block text-[11px] text-txt3 mt-[2px] truncate">{r.subtitle}</span>}
                </span>
                <span className="justify-self-end text-[10px] tracking-[1px] text-txt2 border border-borderstrong px-[6px] py-[3px]">{r.service}</span>
              </button>
            ))}
          </div>
        )}

        {allOffline && (
          <div className="border border-dashed border-danger bg-[#150c0b] px-[34px] py-[34px] text-center">
            <div className="font-display text-[20px] tracking-[3px] text-danger mb-2">VAULT OFFLINE</div>
            <div className="text-[11px] tracking-[1px] text-txt3">// NO SERVICES RESPONDED</div>
          </div>
        )}

        {emptyMatch && (
          <div className="border border-dashed border-borderstrong bg-rail px-[34px] py-[34px] text-center">
            <div className="font-display text-[20px] tracking-[3px] text-txt5 mb-2">NOTHING IN THE VAULT</div>
            <div className="text-[11px] tracking-[1px] text-txt4">// 0 MATCHES ACROSS 5 SERVICES — REFINE QUERY OR RAID DISCOVER</div>
          </div>
        )}
      </div>
    </>
  )
}
