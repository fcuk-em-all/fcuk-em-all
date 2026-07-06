import { Lamp } from './Lamp'
import type { Page } from '../App'

const NAV: { key: string; glyph: string }[] = [
  { key: 'HOME', glyph: '▣' },
  { key: 'VAULT', glyph: '⌕' },
  { key: 'DISCOVER', glyph: '⇩' },
  { key: 'USERS', glyph: '⚿' },
  { key: 'LAUNCH', glyph: '⏻' },
]

export default function Sidebar({ page, setPage, uptime, username, locked }: {
  page: Page; setPage: (p: Page) => void; uptime: string; username: string; locked?: boolean
}) {
  return (
    <aside className="relative flex flex-col flex-none self-stretch w-[248px] bg-rail border-r border-bordermid font-mono">
      <div className="absolute top-0 right-0 bottom-0 w-[6px] hazard-v" />
      <div className="px-5 pt-5 pb-[18px] border-b border-hair">
        <div className="border border-borderstrong bg-black p-[10px]">
          <img src="/logo.png" alt="FCUK-EM-ALL" className="block w-full" style={{ filter: 'grayscale(1) contrast(1.05)' }} />
        </div>
      </div>
      <nav className="flex flex-col flex-1 gap-[6px] px-[14px] py-[18px]">
        <div className="px-2 pb-[10px] text-[10px] tracking-[3px] text-txt4">// CONTROL PLANE</div>
        {NAV.map((item) => {
          const active = item.key === page
          const disabled = !!locked
          return (
            <button
              key={item.key}
              type="button"
              disabled={disabled}
              onClick={() => { if (!disabled) setPage(item.key as Page) }}
              className={[
                'flex items-center gap-3 p-3 text-left border-l-[3px] transition-colors',
                active ? 'bg-surface border-accent text-txt' : 'bg-transparent border-transparent text-txt2',
                disabled ? 'cursor-not-allowed opacity-40' : 'cursor-pointer hover:text-txt',
              ].join(' ')}
            >
              <span className={['w-[18px] text-center', active ? 'text-accent' : ''].join(' ')}>{item.glyph}</span>
              <span className="font-display text-[14px] tracking-[1px]">{item.key}</span>
            </button>
          )
        })}
      </nav>
      <div className="px-[18px] py-4 border-t border-hair text-[11px] tracking-[.5px] text-txt2">
        <div className="flex items-center gap-2 mb-2">
          <Lamp kind="online" size={9} glow={8} round />
          <span className="text-txt">SYS OPERATIONAL</span>
        </div>
        <div className="text-txt4">UPTIME {uptime}</div>
        <div className="text-txt4">OP: {username.toUpperCase()} · CLR-9</div>
        <button
          type="button"
          onClick={() => { const base = window.location.hostname.replace(/^stream\./, ''); window.location.href = `https://auth.${base}/logout?rd=` + encodeURIComponent(`https://stream.${base}`) }}
          className="mt-3 w-full border border-danger text-danger font-display text-[11px] tracking-[1px] py-[7px] hover:bg-danger hover:text-ink transition-colors"
        >
          LOGOUT
        </button>
      </div>
    </aside>
  )
}
