import type { Config } from 'tailwindcss'
import { COLORS } from './src/tokens'

export default {
  content: ['./index.html', './src/**/*.{ts,tsx}'],
  theme: {
    extend: {
      colors: {
        base: COLORS.bgBase,
        ink: COLORS.bgBase,
        rail: COLORS.bgRail,
        topbar: COLORS.bgTopbar,
        screen: COLORS.bgScreen,
        surface: COLORS.surface,
        surfacealt: COLORS.surfaceAlt,
        frame: COLORS.frame,
        hair: COLORS.borderHair,
        bordermid: COLORS.borderMid,
        borderstrong: COLORS.borderStrong,
        txt: COLORS.textPrimary,
        txt2: COLORS.textSecondary,
        txt3: COLORS.textLabel,
        txt4: COLORS.textMuted,
        txt5: COLORS.textDim,
        accent: COLORS.accent,
        danger: COLORS.danger,
        hazardDark: COLORS.hazardDark,
        loadingdash: COLORS.loadingDash,
      },
      fontFamily: {
        display: ['"Black Ops One"', 'cursive'],
        mono: ['"JetBrains Mono"', 'monospace'],
      },
      keyframes: {
        lamp: { '0%,100%': { opacity: '1' }, '50%': { opacity: '.55' } },
        redlamp: { '0%,100%': { opacity: '1' }, '50%': { opacity: '.35' } },
        caret: { '0%,100%': { opacity: '1' }, '50%': { opacity: '0' } },
      },
      animation: {
        lamp: 'lamp 2.4s infinite',
        redlamp: 'redlamp 1s infinite',
        caret: 'caret 1.1s steps(1) infinite',
      },
    },
  },
  plugins: [],
} satisfies Config
