import {loadFont} from '@remotion/google-fonts/Inter';

// Ambitious Social design tokens (extracted from ambitious.social :root)
const inter = loadFont('normal', {
  weights: ['400', '500', '600', '700', '800'],
  subsets: ['latin'],
});
loadFont('italic', {weights: ['800', '900'], subsets: ['latin']});

export const FONT = `${inter.fontFamily}, -apple-system, BlinkMacSystemFont, "Helvetica Neue", sans-serif`;
export const MONO = `"SF Mono", ui-monospace, Menlo, Monaco, "Cascadia Code", monospace`;

export const C = {
  bg: '#FFFFFF',
  surface: '#F8F9FA',
  elevated: '#F0F0F0',
  text: '#1C1E21',
  text2: '#65676B',
  text3: '#8A8D91',
  disabled: '#BCC0C4',
  border: '#E1E4E8',
  borderStrong: '#C8CCD0',
  primary: '#4A9EFF',
  primaryDark: '#0051D5',
  primaryLight: 'rgba(74,158,255,0.10)',
  success: '#00C853',
  dark: '#171717',
  hangout: '#5856D6',
  // The Ambitious logo dash (sampled from ambitious.social's favicon mark)
  dashBlue: '#1FA9FF',
};
