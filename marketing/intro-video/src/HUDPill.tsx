import {interpolate, spring, useCurrentFrame, useVideoConfig} from 'remotion';
import {C, FONT} from './theme';

// Mirrors the real Prompter HUD (a dark floating capsule, like Ambitious's
// black pill buttons): waveform while listening, "Crafting your prompt…"
// dots, green check on paste. Accents use the Ambitious primary blue.

const Waveform: React.FC<{frame: number; amp: number}> = ({frame, amp}) => {
  const bars = 16;
  return (
    <div
      style={{
        display: 'flex',
        alignItems: 'center',
        gap: 4.5,
        height: 30,
      }}
    >
      {Array.from({length: bars}).map((_, i) => {
        const raw =
          Math.abs(Math.sin(frame * 0.31 + i * 1.63)) *
          (0.55 + 0.45 * Math.sin(frame * 0.11 + i * 0.77));
        const level = Math.max(0.1, Math.min(1, raw * amp));
        return (
          <div
            key={i}
            style={{
              width: 4.5,
              height: 5 + 23 * level,
              borderRadius: 3,
              backgroundColor: `rgba(255,255,255,${0.5 + 0.5 * level})`,
            }}
          />
        );
      })}
    </div>
  );
};

const ProcessingDots: React.FC<{frame: number}> = ({frame}) => {
  return (
    <div style={{display: 'flex', gap: 5}}>
      {[0, 1, 2].map((i) => {
        const phase = (Math.sin(frame * 0.35 - i * 1.1) + 1) / 2;
        return (
          <div
            key={i}
            style={{
              width: 7.5,
              height: 7.5,
              borderRadius: 4,
              backgroundColor: C.primary,
              opacity: 0.35 + 0.65 * phase,
              transform: `scale(${0.85 + 0.15 * phase})`,
            }}
          />
        );
      })}
    </div>
  );
};

export const CheckIcon: React.FC = () => (
  <svg width="19" height="19" viewBox="0 0 20 20">
    <circle cx="10" cy="10" r="10" fill={C.success} />
    <path
      d="M5.5 10.4 L8.6 13.4 L14.5 7"
      stroke="#fff"
      strokeWidth="2.2"
      fill="none"
      strokeLinecap="round"
      strokeLinejoin="round"
    />
  </svg>
);

export const HUDPill: React.FC<{
  processingAt: number;
  successAt: number;
  fadeAt: number;
}> = ({processingAt, successAt, fadeAt}) => {
  const frame = useCurrentFrame();
  const {fps} = useVideoConfig();

  const enter = spring({
    frame,
    fps,
    config: {damping: 13, stiffness: 140, mass: 0.7},
  });

  const XFADE = 7;
  const state =
    frame < processingAt ? 'listening' : frame < successAt ? 'processing' : 'success';

  const widthFor = {listening: 342, processing: 268, success: 306} as const;
  const width = interpolate(
    frame,
    [
      processingAt - 1,
      processingAt + XFADE,
      successAt - 1,
      successAt + XFADE,
    ],
    [
      widthFor.listening,
      widthFor.processing,
      widthFor.processing,
      widthFor.success,
    ],
    {extrapolateLeft: 'clamp', extrapolateRight: 'clamp'}
  );

  const contentOpacity =
    state === 'listening'
      ? interpolate(frame, [processingAt - 5, processingAt], [1, 0], {
          extrapolateLeft: 'clamp',
          extrapolateRight: 'clamp',
        })
      : state === 'processing'
        ? interpolate(
            frame,
            [processingAt + 1, processingAt + XFADE, successAt - 5, successAt],
            [0, 1, 1, 0],
            {extrapolateLeft: 'clamp', extrapolateRight: 'clamp'}
          )
        : interpolate(frame, [successAt + 1, successAt + XFADE], [0, 1], {
            extrapolateLeft: 'clamp',
            extrapolateRight: 'clamp',
          });

  const fadeOut = interpolate(frame, [fadeAt, fadeAt + 12], [1, 0], {
    extrapolateLeft: 'clamp',
    extrapolateRight: 'clamp',
  });

  const dotPulse = 1 + 0.13 * Math.sin(frame * 0.26);
  const listeningAmp = interpolate(frame, [0, 26], [0.35, 1], {
    extrapolateLeft: 'clamp',
    extrapolateRight: 'clamp',
  });

  return (
    <div
      style={{
        position: 'absolute',
        left: 0,
        right: 0,
        bottom: 74,
        display: 'flex',
        justifyContent: 'center',
        opacity: fadeOut,
      }}
    >
      <div
        style={{
          width,
          height: 58,
          borderRadius: 999,
          backgroundColor: C.dark,
          border: '1px solid rgba(255,255,255,0.08)',
          boxShadow: '0 16px 44px rgba(28,30,33,0.3)',
          display: 'flex',
          alignItems: 'center',
          justifyContent: 'center',
          transform: `scale(${0.55 + 0.45 * enter}) translateY(${(1 - enter) * 46}px)`,
          opacity: enter,
        }}
      >
        <div
          style={{
            opacity: contentOpacity,
            display: 'flex',
            alignItems: 'center',
            gap: 12,
          }}
        >
          {state === 'listening' && (
            <>
              <div
                style={{
                  width: 10,
                  height: 10,
                  borderRadius: 5,
                  backgroundColor: C.primary,
                  boxShadow: '0 0 12px rgba(74,158,255,0.9)',
                  transform: `scale(${dotPulse})`,
                }}
              />
              <Waveform frame={frame} amp={listeningAmp} />
              <div
                style={{
                  fontFamily: FONT,
                  fontSize: 11.5,
                  fontWeight: 700,
                  letterSpacing: '0.06em',
                  color: 'rgba(255,255,255,0.95)',
                  backgroundColor: 'rgba(74,158,255,0.45)',
                  borderRadius: 5,
                  padding: '3px 8px',
                }}
              >
                PROMPT
              </div>
            </>
          )}
          {state === 'processing' && (
            <>
              <ProcessingDots frame={frame} />
              <div
                style={{
                  fontFamily: FONT,
                  fontSize: 16.5,
                  fontWeight: 500,
                  color: 'rgba(255,255,255,0.94)',
                }}
              >
                Crafting your prompt…
              </div>
            </>
          )}
          {state === 'success' && (
            <>
              <CheckIcon />
              <div
                style={{
                  fontFamily: FONT,
                  fontSize: 16.5,
                  fontWeight: 500,
                  color: 'rgba(255,255,255,0.94)',
                }}
              >
                Pasted at your cursor
              </div>
            </>
          )}
        </div>
      </div>
    </div>
  );
};
