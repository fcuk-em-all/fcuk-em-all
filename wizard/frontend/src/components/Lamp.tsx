import { COLORS } from '../tokens'

type Kind = 'online' | 'offline' | 'idle'

export function Lamp({ kind, size = 9, glow = 8, round = false }: {
  kind: Kind; size?: number; glow?: number; round?: boolean
}) {
  const color = kind === 'online' ? COLORS.accent : kind === 'offline' ? COLORS.danger : COLORS.textDim
  const anim = kind === 'online' ? 'animate-lamp' : kind === 'offline' ? 'animate-redlamp' : ''
  return (
    <span
      aria-hidden="true"
      className={anim}
      style={{
        width: size,
        height: size,
        background: color,
        borderRadius: round ? '50%' : 0,
        boxShadow: kind === 'idle' ? undefined : `0 0 ${glow}px ${color}`,
        display: 'inline-block',
        flex: '0 0 auto',
      }}
    />
  )
}
