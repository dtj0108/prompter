import {
  AbsoluteFill,
  Easing,
  interpolate,
  spring,
  useCurrentFrame,
  useVideoConfig,
} from 'remotion';
import {C, FONT} from '../theme';
import {Lockup} from '../Lockup';

// Real numbers from Prompter's Insights (history.jsonl), first week of use.
const STATS: {value: number; decimals?: number; label: string}[] = [
  {value: 8329, label: 'words spoken'},
  {value: 217, label: 'words per minute'},
  {value: 2.8, decimals: 1, label: 'hours saved'},
];

const StatCard: React.FC<{
  value: number;
  decimals?: number;
  label: string;
  delay: number;
}> = ({value, decimals, label, delay}) => {
  const frame = useCurrentFrame();
  const {fps} = useVideoConfig();

  const pop = spring({
    frame: frame - delay,
    fps,
    config: {damping: 13, stiffness: 140, mass: 0.7},
  });
  const count = interpolate(frame, [delay, delay + 44], [0, value], {
    extrapolateLeft: 'clamp',
    extrapolateRight: 'clamp',
    easing: Easing.out(Easing.cubic),
  });
  const display = decimals
    ? count.toFixed(decimals)
    : Math.round(count).toLocaleString('en-US');

  return (
    <div
      style={{
        width: 244,
        padding: '24px 20px 22px',
        backgroundColor: '#FFFFFF',
        border: `1px solid ${C.border}`,
        borderRadius: 16,
        boxShadow: '0 14px 36px rgba(28,30,33,0.08), 0 2px 8px rgba(28,30,33,0.04)',
        textAlign: 'center',
        opacity: pop,
        transform: `translateY(${(1 - pop) * 26}px) scale(${0.92 + 0.08 * pop})`,
      }}
    >
      <div
        style={{
          fontFamily: FONT,
          fontSize: 42,
          fontWeight: 800,
          letterSpacing: '-0.02em',
          color: C.text,
          fontVariantNumeric: 'tabular-nums',
        }}
      >
        {display}
      </div>
      <div
        style={{
          marginTop: 6,
          fontFamily: FONT,
          fontSize: 15,
          fontWeight: 500,
          color: C.text3,
        }}
      >
        {label}
      </div>
    </div>
  );
};

export const Outro: React.FC = () => {
  const frame = useCurrentFrame();

  const tagIn = interpolate(frame, [16, 28], [0, 1], {
    extrapolateLeft: 'clamp',
    extrapolateRight: 'clamp',
  });

  return (
    <AbsoluteFill style={{alignItems: 'center', justifyContent: 'center'}}>
      <Lockup size={72} delay={4} />
      <div
        style={{
          marginTop: 36,
          fontFamily: FONT,
          fontSize: 28,
          fontWeight: 600,
          color: C.text,
          opacity: tagIn,
          transform: `translateY(${(1 - tagIn) * 12}px)`,
        }}
      >
        Perfect prompts, every time.
      </div>
      <div style={{display: 'flex', gap: 20, marginTop: 46}}>
        {STATS.map((s, i) => (
          <StatCard key={s.label} {...s} delay={30 + i * 8} />
        ))}
      </div>
      <div
        style={{
          marginTop: 40,
          fontFamily: FONT,
          fontSize: 15.5,
          fontWeight: 500,
          color: C.text3,
          letterSpacing: '0.04em',
          opacity: interpolate(frame, [60, 74], [0, 1], {
            extrapolateLeft: 'clamp',
            extrapolateRight: 'clamp',
          }),
        }}
      >
        Prompt Mode&nbsp;&nbsp;·&nbsp;&nbsp;hold right ⌘&nbsp;&nbsp;·&nbsp;&nbsp;macOS
      </div>
    </AbsoluteFill>
  );
};
