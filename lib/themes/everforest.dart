// Everforest theme for Spotube.
//
// Colours copied from Feishin's "Everforest Dark" theme
// (src/shared/themes/everforest-dark/everforest-dark.ts) and filled in from
// the official Everforest palette (github.com/sainnhe/everforest) where
// Feishin has no matching token. Type scale, weights and corner sizes copied
// from Feishin's Mantine theme (src/renderer/themes/mantine-theme.tsx).
//
// Local design decision, 2026-10-19: this is the only colour scheme the app
// uses. The accent-colour picker in Settings is left in place but ignored.

import 'package:shadcn_flutter/shadcn_flutter.dart';

// ---- Everforest palette (dark, "hard" background as Feishin uses it) ------
const _dBgDim = Color(0xFF1E2326);
const _dBg0 = Color(0xFF232A2E); // Feishin background rgb(35,42,46)
const _dBg1 = Color(0xFF2D353B);
const _dBg2 = Color(0xFF343F44);
const _dSurface = Color(0xFF343F38); // Feishin surface rgb(52,63,56)
const _dBg3 = Color(0xFF3D484D);
const _dBg4 = Color(0xFF475258);
const _dFg = Color(0xFFD3C6AA); // Feishin foreground rgb(211,198,170)
const _dGrey1 = Color(0xFF859289);
const _dGreen = Color(0xFFA7C080); // Feishin primary rgb(167,192,128)
const _dRed = Color(0xFFE67E80);
const _dOrange = Color(0xFFE69875);
const _dYellow = Color(0xFFDBBC7F);
const _dBlue = Color(0xFF7FBBB3);
const _dPurple = Color(0xFFD699B6);

// ---- Everforest palette (light, "medium") ----------------------------------
const _lBgDim = Color(0xFFF2EFDF);
const _lBg0 = Color(0xFFFDF6E3);
const _lBg1 = Color(0xFFF4F0D9);
const _lBg2 = Color(0xFFEFEBD4);
const _lBg3 = Color(0xFFE6E2CC);
const _lBg4 = Color(0xFFE0DCC7);
const _lFg = Color(0xFF5C6A72);
const _lGrey1 = Color(0xFF939F91);
const _lGreen = Color(0xFF8DA101);
const _lRed = Color(0xFFF85552);
const _lOrange = Color(0xFFF57D26);
const _lYellow = Color(0xFFDFA000);
const _lBlue = Color(0xFF3A94C5);
const _lPurple = Color(0xFFDF69BA);

/// Returns the Everforest colour scheme for [mode]. Same call shape as
/// `LegacyColorSchemes.slate` so it drops into `colorSchemeMap` if wanted.
ColorScheme everforestColorScheme(ThemeMode mode) {
  switch (mode) {
    case ThemeMode.light:
      return const ColorScheme(
        brightness: Brightness.light,
        background: _lBg0,
        foreground: _lFg,
        card: _lBg1,
        cardForeground: _lFg,
        popover: _lBg1,
        popoverForeground: _lFg,
        primary: _lGreen,
        primaryForeground: _lBg0,
        secondary: _lBg3,
        secondaryForeground: _lFg,
        muted: _lBg2,
        mutedForeground: _lGrey1,
        accent: _lBg3,
        accentForeground: _lFg,
        destructive: _lRed,
        destructiveForeground: _lBg0,
        border: _lBg4,
        input: _lBg4,
        ring: _lGreen,
        chart1: _lGreen,
        chart2: _lBlue,
        chart3: _lYellow,
        chart4: _lOrange,
        chart5: _lPurple,
        sidebar: _lBgDim,
        sidebarForeground: _lFg,
        sidebarPrimary: _lGreen,
        sidebarPrimaryForeground: _lBg0,
        sidebarAccent: _lBg2,
        sidebarAccentForeground: _lFg,
        sidebarBorder: _lBg4,
        sidebarRing: _lGreen,
      );
    case ThemeMode.dark:
    case ThemeMode.system:
      return const ColorScheme(
        brightness: Brightness.dark,
        background: _dBg0,
        foreground: _dFg,
        card: _dSurface,
        cardForeground: _dFg,
        popover: _dBg1,
        popoverForeground: _dFg,
        primary: _dGreen,
        primaryForeground: _dBg0,
        secondary: _dBg3,
        secondaryForeground: _dFg,
        muted: _dBg2,
        mutedForeground: _dGrey1,
        accent: _dBg4,
        accentForeground: _dFg,
        destructive: _dRed,
        destructiveForeground: _dBg0,
        border: _dBg4,
        input: _dBg4,
        ring: _dGreen,
        chart1: _dGreen,
        chart2: _dBlue,
        chart3: _dYellow,
        chart4: _dOrange,
        chart5: _dPurple,
        sidebar: _dBgDim,
        sidebarForeground: _dFg,
        sidebarPrimary: _dGreen,
        sidebarPrimaryForeground: _dBg0,
        sidebarAccent: _dBg1,
        sidebarAccentForeground: _dFg,
        sidebarBorder: _dBg4,
        sidebarRing: _dGreen,
      );
  }
}

/// Inter, with Feishin's sizes: body 14, small 13, labels 11, headings heavy.
const everforestTypography = Typography.geist(
  sans: TextStyle(fontFamily: 'Inter'),
  mono: TextStyle(fontFamily: 'Ubuntu Mono'),
  xSmall: TextStyle(fontSize: 11),
  small: TextStyle(fontSize: 13),
  base: TextStyle(fontSize: 14),
  large: TextStyle(fontSize: 16),
  xLarge: TextStyle(fontSize: 18),
  x2Large: TextStyle(fontSize: 20),
  x3Large: TextStyle(fontSize: 24),
  x4Large: TextStyle(fontSize: 28),
  x5Large: TextStyle(fontSize: 32),
  h1: TextStyle(fontSize: 36, fontWeight: FontWeight.w900, height: 44 / 36),
  h2: TextStyle(fontSize: 30, fontWeight: FontWeight.w900, height: 38 / 30),
  h3: TextStyle(fontSize: 24, fontWeight: FontWeight.w900, height: 32 / 24),
  h4: TextStyle(fontSize: 20, fontWeight: FontWeight.w900, height: 30 / 20),
  p: TextStyle(fontSize: 14, fontWeight: FontWeight.w400),
  lead: TextStyle(fontSize: 18),
  textLarge: TextStyle(fontSize: 18, fontWeight: FontWeight.w600),
  textSmall: TextStyle(fontSize: 13, fontWeight: FontWeight.w500),
  textMuted: TextStyle(fontSize: 13, fontWeight: FontWeight.w400),
  inlineCode: TextStyle(
      fontFamily: 'Ubuntu Mono', fontSize: 13, fontWeight: FontWeight.w600),
);

/// Feishin's default corner is 3px, cards 12px. shadcn_flutter scales one
/// multiplier (radiusSm = r*8, radiusMd = r*12, radiusLg = r*16), so 0.35
/// gives roughly 3 / 4 / 6 px.
const everforestRadius = 0.35;
