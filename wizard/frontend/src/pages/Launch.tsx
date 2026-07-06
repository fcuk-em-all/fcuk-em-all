import { useEffect, useState } from 'react'
import { getHealth, type Health } from '../api'
import { Lamp } from '../components/Lamp'
import CornerBrackets from '../components/CornerBrackets'

// Deep-link base derived from the appliance domain the wizard is served on
// (e.g. stream.example.com -> example.com), so links follow any domain.
const BASE_DOMAIN =
  typeof window !== 'undefined'
    ? window.location.hostname.replace(/^stream\./, '')
    : 'fcuk-em-all.com'
const svc = (host: string) => `https://${host}.${BASE_DOMAIN}`

const SERVICES = [
  { name: 'JELLYFIN', kind: 'VIDEO', key: 'jellyfin', url: svc('jellyfin'), purpose: 'Films & shows' },
  { name: 'NAVIDROME', kind: 'MUSIC', key: 'navidrome', url: svc('navidrome'), purpose: 'Music library' },
  { name: 'KAVITA', kind: 'BOOKS', key: 'kavita', url: svc('kavita'), purpose: 'Books & comics' },
  { name: 'AUDIOBOOKSHELF', kind: 'AUDIOBOOKS', key: 'audiobookshelf', url: svc('audiobookshelf'), purpose: 'Audiobooks & podcasts' },
  { name: 'IMMICH', kind: 'PHOTOS', key: 'immich', url: svc('immich'), purpose: 'Photos & videos' },
  { name: 'JELLYSEERR', kind: 'REQUESTS', key: 'jellyseerr', url: svc('requests'), purpose: 'Request movies & shows' },
] as const

export default function Launch() {
  const [health, setHealth] = useState<Health | null>(null)
  useEffect(() => {
    let alive = true
    getHealth().then((h) => { if (alive) setHealth(h) }).catch(() => { if (alive) setHealth({}) })
    return () => { alive = false }
  }, [])

  const online = (k: string) => health?.[k] === 'ONLINE'
  const count = SERVICES.filter((s) => online(s.key)).length

  return (
    <>
      <div className="flex-none h-[60px] flex items-center justify-between px-[26px] border-b border-bordermid bg-topbar">
        <div className="flex items-baseline gap-[14px]">
          <div className="font-display text-[24px] tracking-[2px] text-txt">LAUNCH</div>
          <div className="text-[11px] tracking-[1px] text-txt3">// SIX SYSTEMS — LAUNCH SEQUENCE</div>
        </div>
        <div className="text-[11px] text-txt2">{health ? `${count} / 6 ONLINE` : '— / 6 ONLINE'}</div>
      </div>

      <div className="flex-1 overflow-auto px-[26px] py-6">
        <div className="grid grid-cols-3 gap-4">
          {SERVICES.map((s) => {
            const up = online(s.key)
            return (
              <div key={s.key} className="relative bg-surface border border-bordermid p-5 flex flex-col gap-4">
                <CornerBrackets big />
                <div className="flex justify-between items-start">
                  <div>
                    <div className="font-display text-[20px] tracking-[1px] text-txt">{s.name}</div>
                    <div className="mt-[3px] text-[10px] tracking-[3px] text-txt3">{s.kind}</div>
                  </div>
                  <div className="flex items-center gap-[7px]">
                    <Lamp kind={up ? 'online' : 'offline'} size={11} glow={10} round />
                    <span className={['text-[10px] tracking-[1px]', up ? 'text-accent' : 'text-danger'].join(' ')}>
                      {health ? (up ? 'ONLINE' : 'OFFLINE') : '···'}
                    </span>
                  </div>
                </div>
                <div className="text-[10px] tracking-[1px] text-txt4">{s.purpose}</div>
                <a
                  href={s.url}
                  target="_blank"
                  rel="noopener noreferrer"
                  className="mt-auto w-full text-center bg-accent text-ink font-display text-[13px] tracking-[2px] py-3 no-underline hover:bg-white transition-colors"
                >
                  LAUNCH ↗
                </a>
              </div>
            )
          })}
          {/* Ep4 Pass4b: 6 panels fill the grid - reserved slot removed */}
        </div>
      </div>
    </>
  )
}
