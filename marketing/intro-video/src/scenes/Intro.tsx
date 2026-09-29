import {AbsoluteFill, interpolate, useCurrentFrame} from 'remotion';
import {C, FONT} from '../theme';
import {Lockup} from '../Lockup';

export const Intro: React.FC = () => {
  const frame = useCurrentFrame();

  const subIn = interpolate(frame, [20, 32], [0, 1], {
    extrapolateLeft: 'clamp',
    extrapolateRight: 'clamp',
  });
  const exit = interpolate(frame, [46, 58], [1, 0], {
    extrapolateLeft: 'clamp',
    extrapolateRight: 'clamp',
  });

  return (
    <AbsoluteFill
      style={{
        alignItems: 'center',
        justifyContent: 'center',
        opacity: exit,
        transform: `scale(${1 + (1 - exit) * 0.04})`,
      }}
    >
      <Lockup size={92} delay={4} />
      <div
        style={{
          marginTop: 40,
          fontFamily: FONT,
          fontSize: 24,
          fontWeight: 500,
          color: C.text2,
          opacity: subIn,
          transform: `translateY(${(1 - subIn) * 10}px)`,
        }}
      >
        Perfect prompts, every time.
      </div>
    </AbsoluteFill>
  );
};
