import { useCallback, useEffect, useState } from 'react'
import Sidebar from './components/Sidebar'
import Home from './pages/Home'
import Launch from './pages/Launch'
import Vault from './pages/Vault'
import Discover from './pages/Discover'
import Users from './pages/Users'
import Setup from './pages/Setup'
import Grain from './components/Grain'
import { getMeFull, getSystem, getSetupStatus, type System, type MeInfo } from './api'
import { formatUptime } from './lib/format'

export type Page = 'HOME' | 'VAULT' | 'DISCOVER' | 'USERS' | 'LAUNCH'

export default function App() {
  const [page, setPage] = useState<Page>('HOME')
  const [system, setSystem] = useState<System | null>(null)
  const [me, setMe] = useState<MeInfo | null>(null)
  const [setup, setSetup] = useState<'loading' | 'needed' | 'done'>('loading')

  const loadMe = useCallback(() => {
    getMeFull()
      .then((m) => setMe(m))
      .catch(() => setMe({ username: 'ADMIN', is_admin: true, must_change_password: false }))
  }, [])

  useEffect(() => {
    let alive = true
    const load = () => { getSystem().then((s) => { if (alive) setSystem(s) }).catch(() => {}) }
    load()
    loadMe()
    const t = setInterval(load, 15000)
    return () => { alive = false; clearInterval(t) }
  }, [loadMe])

  useEffect(() => {
    getSetupStatus()
      .then((s) => setSetup(s.complete ? 'done' : 'needed'))
      .catch(() => setSetup('done'))
  }, [])

  if (setup === 'loading') return <div className="app-bg min-h-screen" />
  if (setup === 'needed') return <Setup onComplete={() => setSetup('done')} />

  const locked = !!me?.must_change_password
  const current: Page = locked ? 'USERS' : page

  return (
    <div className="app-bg min-h-screen text-txt font-mono flex relative overflow-hidden">
      <Sidebar page={current} setPage={setPage} locked={locked} uptime={formatUptime(system?.uptime_seconds)} username={me?.username ?? 'ADMIN'} />
      <main className="flex-1 flex flex-col min-w-0 h-screen overflow-hidden">
        {current === 'HOME' && <Home system={system} />}
        {current === 'VAULT' && <Vault />}
        {current === 'DISCOVER' && <Discover />}
        {current === 'USERS' && <Users me={me} onChanged={loadMe} />}
        {current === 'LAUNCH' && <Launch />}
      </main>
      <Grain />
    </div>
  )
}
