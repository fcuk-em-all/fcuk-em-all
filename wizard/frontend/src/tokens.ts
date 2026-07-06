// FCUK-EM-ALL design tokens - single typed source of truth. Every hex lives here;
// tailwind.config.ts imports COLORS to build named utilities so no raw hex ever
// appears in JSX. Values taken verbatim from the design reference spec sheet (2g).
export const COLORS = {
  bgBase: '#0A0B0C',       // base background
  bgRail: '#0B0C0D',       // sidebar / terminal input surface
  bgTopbar: '#0C0D0F',     // top bar surface
  bgScreen: '#0D0E10',     // screen / gauge-empty segment
  surface: '#141618',      // card / panel surface
  surfaceAlt: '#1C1F21',   // gauge remainder fill
  frame: '#2A2D30',        // outer screen frame
  borderHair: '#1C1F21',   // hairline / row divider (border level 1)
  borderMid: '#26292C',    // panel border (border level 2)
  borderStrong: '#2F3336', // input / stamp border (border level 3)
  textPrimary: '#ECEAE4',  // white text
  textSecondary: '#8A8D8F',// secondary text
  textLabel: '#6B6E70',    // labels / meta
  textMuted: '#5F6264',    // muted
  textDim: '#4C5052',      // idle / disabled
  accent: '#FFD400',       // hazard yellow
  danger: '#E33B2E',       // alert red
  hazardDark: '#111111',   // hazard-tape dark stripe
  loadingDash: '#2F3336',  // loading/empty em-dash
} as const

export const FONTS = {
  display: '"Black Ops One", cursive',
  mono: '"JetBrains Mono", monospace',
} as const

// Decorative techniques (also expressed as CSS component classes in index.css,
// kept here as typed constants for reference / any inline use).
export const GRADIENTS = {
  hazardV: `repeating-linear-gradient(180deg, ${COLORS.accent} 0 14px, ${COLORS.hazardDark} 14px 28px)`,
  hazardH: `repeating-linear-gradient(45deg, ${COLORS.accent} 0 16px, ${COLORS.hazardDark} 16px 32px)`,
  gaugeFill: `repeating-linear-gradient(90deg, ${COLORS.accent} 0 6px, ${COLORS.bgScreen} 6px 8px)`,
} as const
