import { useEffect, useState } from 'react'
import { getStats, getRecent, type Stats, type RecentItem, type System } from '../api'
import { formatCount, relativeTime, humanCapacity } from '../lib/format'
import { Lamp } from '../components/Lamp'
import CornerBrackets from '../components/CornerBrackets'

const COUNTERS = [
  { label: 'FILMS', key: 'films', service: 'JELLYFIN' },
  { label: 'ALBUMS', key: 'albums', service: 'NAVIDROME' },
  { label: 'BOOKS', key: 'books', service: 'KAVITA' },
  { label: 'AUDIOBOOKS', key: 'audiobooks', service: 'AUDIOBOOKSHELF' },
  { label: 'PHOTOS', key: 'photos', service: 'IMMICH' },
] as const

function pad(n: number) { return n < 10 ? `0${n}` : `${n}` }

function useClock() {
  const [now, setNow] = useState(() => new Date())
  useEffect(() => {
    const t = setInterval(() => setNow(new Date()), 1000)
    return () => clearInterval(t)
  }, [])
  return now
}

export default function Home({ system }: { system: System | null }) {
  const [stats, setStats] = useState<Stats | null>(null)
  const [recent, setRecent] = useState<RecentItem[] | null>(null)
  const [loading, setLoading] = useState(true)
  const now = useClock()

  useEffect(() => {
    let alive = true
    Promise.allSettled([getStats(), getRecent()]).then(([s, r]) => {
      if (!alive) return
      if (s.status === 'fulfilled') setStats(s.value)
      if (r.status === 'fulfilled') setRecent(r.value)
      setLoading(false)
    })
    return () => { alive = false }
  }, [])

  const dateStr = `${now.getFullYear()}·${pad(now.getMonth() + 1)}·${pad(now.getDate())}`
  const timeStr = `${pad(now.getHours())}:${pad(now.getMinutes())}:${pad(now.getSeconds())}`

  const health = [
    { label: 'CPU LOAD', val: system?.cpu_pct, unit: '%', tag: 'NOMINAL', kind: 'online' as const },
    { label: 'RAM', val: system?.ram_pct, unit: '%', tag: 'NOMINAL', kind: 'online' as const },
    { label: 'DISK', val: system?.disk_pct, unit: '%', tag: 'STORED', kind: 'idle' as const },
  ]

  const diskPct = system ? Math.max(0, Math.min(100, system.disk_pct)) : 0
  const used = system ? humanCapacity(system.disk_used_bytes) : null
  const total = system ? humanCapacity(system.disk_total_bytes) : null

  return (
    <>
      <div className="flex-none h-[60px] flex items-center justify-between px-[26px] border-b border-bordermid bg-topbar">
        <div className="flex items-baseline gap-[14px]">
          <div className="font-display text-[24px] tracking-[2px] text-txt">CURRENTLY RIPPED</div>
          <div className="text-[11px] tracking-[1px] text-txt3">// WAR ROOM</div>
        </div>
        <div className="flex items-center gap-[18px] text-[11px] text-txt2">
          <span>{dateStr}</span>
          <span className="text-txt">{timeStr}</span>
          <span className="inline-block px-2 py-[3px] border border-borderstrong text-accent tracking-[2px]" style={{ transform: 'rotate(-1.5deg)' }}>SECURE</span>
        </div>
      </div>

      <div className="flex-1 overflow-auto px-[26px] py-6">
        <div className="grid grid-cols-5 gap-[14px] mb-[22px]">
          {COUNTERS.map((c) => {
            const v = stats ? stats[c.key] : undefined
            const showDash = loading || v === null || v === undefined
            return (
              <div key={c.key} className="relative bg-surface border border-bordermid px-4 pt-[18px] pb-4">
                <CornerBrackets />
                <div className="mb-[10px] text-[10px] tracking-[2px] text-txt3">{c.label}</div>
                <div className={['font-mono font-extrabold text-[38px] leading-none tracking-[-1px]', showDash ? 'text-loadingdash' : 'text-txt'].join(' ')}>
                  {showDash ? '—' : formatCount(v)}
                </div>
                <div className="flex items-center gap-[6px] mt-3 text-[9px] tracking-[1px] text-txt4">
                  <Lamp kind="online" size={6} glow={6} />{c.service}
                </div>
              </div>
            )
          })}
        </div>

        <div className="grid grid-cols-[1.4fr_1fr] gap-[14px] mb-[22px]">
          <div className="bg-surface border border-bordermid px-[18px] py-4">
            <div className="mb-[14px] font-display text-[12px] tracking-[2px] text-txt2">SYSTEM HEALTH</div>
            <div className="grid grid-cols-3 gap-[14px]">
              {health.map((h) => (
                <div key={h.label} className="pl-3 border-l-2 border-borderstrong">
                  <div className="text-[10px] tracking-[1px] text-txt3">{h.label}</div>
                  <div className="font-mono font-bold text-[26px] text-txt">
                    {h.val === undefined ? '—' : Math.round(h.val)}
                    <span className="text-[14px] text-txt3">{h.val === undefined ? '' : h.unit}</span>
                  </div>
                  <div className={['flex items-center gap-[6px] mt-1 text-[9px]', h.kind === 'online' ? 'text-accent' : 'text-txt2'].join(' ')}>
                    <Lamp kind={h.kind} size={7} glow={6} />{h.tag}
                  </div>
                </div>
              ))}
            </div>
          </div>

          <div className="bg-surface border border-bordermid px-[18px] py-4">
            <div className="flex justify-between items-baseline mb-[14px]">
              <div className="font-display text-[12px] tracking-[2px] text-txt2">VAULT CAPACITY</div>
              <div className="font-mono font-bold text-[13px] text-accent">{system ? `${Math.round(system.disk_pct)}%` : '—'}</div>
            </div>
            <div className="flex gap-[3px] h-[26px] mb-[10px]">
              <div className="gauge-fill" style={{ flex: diskPct }} />
              <div className="bg-surfacealt border border-bordermid" style={{ flex: 100 - diskPct }} />
            </div>
            <div className="flex justify-between text-[11px] text-txt2">
              <span className="text-txt">{used ? `${used.value} ${used.unit}` : '—'}</span>
              <span>/ {total ? `${total.value} ${total.unit}` : '—'}</span>
            </div>
          </div>
        </div>

        <div className="bg-surface border border-bordermid">
          <div className="flex justify-between items-center px-[18px] py-[14px] border-b border-bordermid">
            <div className="font-display text-[12px] tracking-[2px] text-txt2">RECENT ADDITIONS — LAST 7 DAYS</div>
            <div className="text-[10px] text-txt4">SCROLL ▼</div>
          </div>
          <div>
            {recent === null && loading && (
              <div className="px-[18px] py-[14px] text-[12px] text-txt3">SCANNING…</div>
            )}
            {recent !== null && recent.length === 0 && (
              <div className="px-[18px] py-[14px] text-[12px] text-txt3">NOTHING RECENT</div>
            )}
            {recent && recent.map((it, idx) => (
              <div key={idx} className="grid grid-cols-[90px_1fr_130px] gap-3 items-center px-[18px] py-[11px] border-b border-hair text-[12px] last:border-b-0">
                <span className="text-[10px] tracking-[1px] text-accent">[{it.type}]</span>
                <span className="text-txt truncate">{it.title}</span>
                <span className="text-right text-txt3">{relativeTime(it.added)}</span>
              </div>
            ))}
          </div>
        </div>
      </div>
    </>
  )
}
