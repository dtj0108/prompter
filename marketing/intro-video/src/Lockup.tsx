import {
  Easing,
  interpolate,
  spring,
  useCurrentFrame,
  useVideoConfig,
} from 'remotion';
import {C, FONT} from './theme';

// The brand lockup, styled the way the Ambitious logo works:
// a lowercase heavy-italic wordmark with the slanted blue dash beneath it.
export const Lockup: React.FC<{size: number; delay?: number}> = ({
  size,
  delay = 0,
}) => {
  const frame = useCurrentFrame();
  const {fps} = useVideoConfig();

  const wordIn = spring({
    frame: frame - delay,
    fps,
    config: {damping: 14, stiffness: 120, mass: 0.85},
  });
  const dashT = interpolate(frame, [delay + 9, delay + 24], [0, 1], {
    extrapolateLeft: 'clamp',
    extrapolateRight: 'clamp',
    easing: Easing.out(Easing.cubic),
  });

  return (
    <div
      style={{
        display: 'flex',
        flexDirection: 'column',
        alignItems: 'center',
      }}
    >
      <div
        style={{
          fontFamily: FONT,
          fontStyle: 'italic',
          fontWeight: 900,
          fontSize: size,
          letterSpacing: '-0.045em',
          color: C.text,
          opacity: wordIn,
          transform: `translateY(${(1 - wordIn) * 24}px)`,
        }}
      >
        ambitious prompts
      </div>
      <div
        style={{
          marginTop: size * 0.22,
          width: size * 2.1,
          height: Math.max(8, size * 0.115),
          borderRadius: size * 0.045,
          backgroundColor: C.dashBlue,
          transform: `skewX(-14deg) scaleX(${dashT})`,
          opacity: dashT,
        }}
      />
    </div>
  );
};
