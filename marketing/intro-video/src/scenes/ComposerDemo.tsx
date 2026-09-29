import {
  AbsoluteFill,
  Easing,
  interpolate,
  random,
  spring,
  useCurrentFrame,
  useVideoConfig,
} from 'remotion';
import {C, FONT, MONO} from '../theme';

// The full demo, all inside one AI chat composer:
//   L6    keycap appears, presses at L14 and stays held
//   L18   the composer text box rises in (placeholder showing)
//   L34   spoken words type INTO the box, word by word
//   L188  processing: box content dims and blurs ("Crafting your prompt…")
//   L200  fillers tumble out of the box, kept words lift away
//   L214  the box grows and the polished prompt replaces the text in place
//   L336  the send button (now live) fires — the prompt flies off to the agent
//   L364  typing dots: the agent is working
const SPEECH_START = 34;
const PROCESSING = 188;
const FALL = 200;
const MORPH = 214;
const CASCADE = 218;
const STAGGER = 2.4;
const SEND_ACTIVE = 264;
const SEND_CLICK = 336;
const FLY = 342;
const COLLAPSE = 346;
const DOTS = 366;

const BOX_W = 980;
const H_EMPTY = 170;
const H_TYPED = 318;
const H_PROMPT = 478;

type Word = {t: string; d: number; filler?: boolean};

const WORDS: Word[] = [
  {t: 'Hey,', d: 5},
  {t: 'can', d: 3},
  {t: 'you', d: 3},
  {t: 'please', d: 3},
  {t: 'add', d: 3},
  {t: 'a', d: 2},
  {t: 'dark', d: 3},
  {t: 'mode', d: 3},
  {t: 'toggle', d: 4},
  {t: 'to', d: 2},
  {t: 'the', d: 2},
  {t: 'settings', d: 4},
  {t: 'screen?', d: 10},
  {t: 'Um...', d: 9, filler: true},
  {t: 'it', d: 3},
  {t: 'should', d: 3},
  {t: 'remember', d: 4},
  {t: 'whatever', d: 3},
  {t: 'they', d: 3},
  {t: 'picked,', d: 7},
  {t: 'and,', d: 4},
  {t: 'uh,', d: 7, filler: true},
  {t: 'make', d: 3},
  {t: 'sure', d: 3},
  {t: 'the', d: 2},
  {t: 'login', d: 3},
  {t: 'page', d: 3},
  {t: "doesn't", d: 3},
  {t: 'look', d: 3},
  {t: 'weird.', d: 9},
  {t: 'Oh', d: 3},
  {t: '—', d: 3},
  {t: 'and', d: 3},
  {t: 'only', d: 3},
  {t: 'the', d: 2},
  {t: 'iOS', d: 4},
  {t: 'app', d: 3},
  {t: 'for', d: 3},
  {t: 'now.', d: 6},
];

const wordStarts = (() => {
  let acc = SPEECH_START;
  return WORDS.map((w) => {
    const s = acc;
    acc += w.d;
    return s;
  });
})();

type Line =
  | {kind: 'h1' | 'h2' | 'p' | 'li' | 'cb'; text: string}
  | {kind: 'blank'};

const LINES: Line[] = [
  {kind: 'h1', text: 'Add a dark-mode toggle to Settings'},
  {kind: 'blank'},
  {kind: 'h2', text: 'Objective'},
  {kind: 'p', text: 'Ship a dark-mode toggle on the settings screen. The'},
  {kind: 'p', text: 'choice persists across launches and applies app-wide.'},
  {kind: 'blank'},
  {kind: 'h2', text: 'Constraints'},
  {kind: 'li', text: 'iOS app only — do not touch other platforms'},
  {kind: 'li', text: 'Persist the selected theme across launches'},
  {kind: 'li', text: 'The login screen must render correctly in dark mode'},
  {kind: 'li', text: 'Inspect existing theme code first; keep the change scoped'},
  {kind: 'blank'},
  {kind: 'h2', text: 'Acceptance criteria'},
  {kind: 'cb', text: 'Toggle in Settings switches themes instantly'},
  {kind: 'cb', text: 'Selection survives an app relaunch'},
  {kind: 'cb', text: 'Login screen verified in both themes'},
];

const Syntax: React.FC<{line: Line}> = ({line}) => {
  const dim = {color: C.disabled};
  switch (line.kind) {
    case 'h1':
      return (
        <span style={{fontSize: 21, fontWeight: 700, color: C.text}}>
          <span style={dim}># </span>
          {line.text}
        </span>
      );
    case 'h2':
      return (
        <span style={{fontSize: 16.5, fontWeight: 600, color: C.primaryDark}}>
          <span style={dim}>## </span>
          {line.text}
        </span>
      );
    case 'p':
      return <span style={{color: '#3A3E44'}}>{line.text}</span>;
    case 'li':
      return (
        <span style={{color: '#3A3E44'}}>
          <span style={{color: C.primary}}>- </span>
          {line.text}
        </span>
      );
    case 'cb':
      return (
        <span style={{color: '#3A3E44', display: 'inline-flex', alignItems: 'center'}}>
          <span style={{color: C.primary}}>-&nbsp;</span>
          <span
            style={{
              display: 'inline-block',
              width: 13,
              height: 13,
              borderRadius: 3.5,
              border: `1.6px solid ${C.borderStrong}`,
              marginRight: 10,
            }}
          />
          {line.text}
        </span>
      );
    default:
      return null;
  }
};

const Keycap: React.FC<{frame: number; fps: number}> = ({frame, fps}) => {
  const enter = spring({
    frame: frame - 6,
    fps,
    config: {damping: 13, stiffness: 150, mass: 0.7},
  });
  const press = interpolate(frame, [14, 17], [0, 1], {
    extrapolateLeft: 'clamp',
    extrapolateRight: 'clamp',
    easing: Easing.out(Easing.quad),
  });
  const exit = interpolate(frame, [32, 46], [1, 0], {
    extrapolateLeft: 'clamp',
    extrapolateRight: 'clamp',
  });
  const ring = interpolate(frame, [15, 34], [0, 1], {
    extrapolateLeft: 'clamp',
    extrapolateRight: 'clamp',
  });

  if (frame > 48) return null;

  return (
    <AbsoluteFill
      style={{
        alignItems: 'center',
        justifyContent: 'center',
        opacity: enter * exit,
        transform: `translateY(${-46 - (1 - exit) * 28}px)`,
      }}
    >
      <div
        style={{
          position: 'absolute',
          width: 110 + ring * 130,
          height: 110 + ring * 130,
          borderRadius: 999,
          border: `2.5px solid rgba(74,158,255,0.75)`,
          opacity: (1 - ring) * 0.7,
        }}
      />
      <div
        style={{
          width: 104,
          height: 104,
          borderRadius: 22,
          background: 'linear-gradient(180deg, #FFFFFF 0%, #F2F4F7 100%)',
          border: `1px solid ${C.borderStrong}`,
          boxShadow: press
            ? '0 3px 10px rgba(28,30,33,0.16), inset 0 1px 0 #fff'
            : '0 12px 28px rgba(28,30,33,0.2), inset 0 1px 0 #fff',
          display: 'flex',
          alignItems: 'center',
          justifyContent: 'center',
          transform: `scale(${0.6 + 0.4 * enter}) translateY(${press * 6}px)`,
          fontFamily: FONT,
          fontSize: 46,
          fontWeight: 500,
          color: C.text,
        }}
      >
        ⌘
      </div>
      <div
        style={{
          marginTop: 26,
          fontFamily: FONT,
          fontSize: 18,
          fontWeight: 500,
          color: C.text2,
          letterSpacing: '0.02em',
        }}
      >
        hold right ⌘ — Prompt Mode
      </div>
    </AbsoluteFill>
  );
};

const SendArrow: React.FC<{color: string}> = ({color}) => (
  <svg width="20" height="20" viewBox="0 0 24 24" fill="none">
    <path
      d="M12 19 V6 M6.5 11.5 L12 6 L17.5 11.5"
      stroke={color}
      strokeWidth="2.6"
      strokeLinecap="round"
      strokeLinejoin="round"
    />
  </svg>
);

const PlusIcon: React.FC = () => (
  <svg width="21" height="21" viewBox="0 0 24 24" fill="none">
    <circle cx="12" cy="12" r="10" stroke={C.disabled} strokeWidth="1.8" />
    <path
      d="M12 8 v8 M8 12 h8"
      stroke={C.disabled}
      strokeWidth="1.8"
      strokeLinecap="round"
    />
  </svg>
);

const SmallMic: React.FC<{active: boolean}> = ({active}) => {
  const col = active ? C.primary : C.disabled;
  return (
    <svg width="19" height="19" viewBox="0 0 48 48" fill="none">
      <rect x="17.5" y="7" width="13" height="21" rx="6.5" fill={col} />
      <path
        d="M12 23 a12 12 0 0 0 24 0"
        stroke={col}
        strokeWidth="4"
        fill="none"
        strokeLinecap="round"
      />
      <line x1="24" y1="35.5" x2="24" y2="41" stroke={col} strokeWidth="4" strokeLinecap="round" />
    </svg>
  );
};

export const ComposerDemo: React.FC<{sceneDuration: number}> = ({
  sceneDuration,
}) => {
  const frame = useCurrentFrame();
  const {fps} = useVideoConfig();

  const boxIn = spring({
    frame: frame - 18,
    fps,
    config: {damping: 14, stiffness: 130, mass: 0.8},
  });

  // Box height: grows while you talk, expands for the prompt, collapses on send.
  const typedH = interpolate(frame, [SPEECH_START, SPEECH_START + 145], [H_EMPTY, H_TYPED], {
    extrapolateLeft: 'clamp',
    extrapolateRight: 'clamp',
    easing: Easing.inOut(Easing.quad),
  });
  const morphT = interpolate(frame, [MORPH, MORPH + 24], [0, 1], {
    extrapolateLeft: 'clamp',
    extrapolateRight: 'clamp',
    easing: Easing.inOut(Easing.cubic),
  });
  const collapseT = interpolate(frame, [COLLAPSE, COLLAPSE + 20], [0, 1], {
    extrapolateLeft: 'clamp',
    extrapolateRight: 'clamp',
    easing: Easing.inOut(Easing.cubic),
  });
  const boxH =
    (frame < MORPH ? typedH : H_TYPED + (H_PROMPT - H_TYPED) * morphT) *
      (1 - collapseT) +
    H_EMPTY * collapseT;

  const exit = interpolate(
    frame,
    [sceneDuration - 16, sceneDuration - 3],
    [1, 0],
    {extrapolateLeft: 'clamp', extrapolateRight: 'clamp'}
  );

  // Captions
  const cap1 = interpolate(frame, [30, 42, 172, 186], [0, 1, 1, 0], {
    extrapolateLeft: 'clamp',
    extrapolateRight: 'clamp',
  });
  const cap2 = interpolate(frame, [226, 238, 318, 330], [0, 1, 1, 0], {
    extrapolateLeft: 'clamp',
    extrapolateRight: 'clamp',
  });
  const cap3 = interpolate(frame, [338, 350, sceneDuration - 20, sceneDuration - 8], [0, 1, 1, 0], {
    extrapolateLeft: 'clamp',
    extrapolateRight: 'clamp',
  });
  const caption =
    cap2 > cap1 && cap2 > cap3
      ? {t: 'IT WRITES THE PROMPT LIKE A PRO', o: cap2}
      : cap3 > cap1
        ? {t: 'AND JUST SENDS IT OFF', o: cap3}
        : {t: 'YOU TALK LIKE A PERSON', o: cap1};

  const dim = interpolate(frame, [PROCESSING, PROCESSING + 18], [0, 1], {
    extrapolateLeft: 'clamp',
    extrapolateRight: 'clamp',
  });

  const placeholderOpacity =
    frame < SPEECH_START + 6
      ? interpolate(frame, [SPEECH_START - 2, SPEECH_START + 5], [1, 0], {
          extrapolateLeft: 'clamp',
          extrapolateRight: 'clamp',
        })
      : interpolate(frame, [COLLAPSE + 16, COLLAPSE + 28], [0, 1], {
          extrapolateLeft: 'clamp',
          extrapolateRight: 'clamp',
        });

  const lastVisible = wordStarts.filter((s) => frame >= s).length - 1;
  const listening = frame < PROCESSING;
  const caretBlink = Math.sin(frame * 0.42) > -0.2 ? 1 : 0.25;

  // Prompt block: fly off to the agent on send
  const flyT = interpolate(frame, [FLY, FLY + 17], [0, 1], {
    extrapolateLeft: 'clamp',
    extrapolateRight: 'clamp',
    easing: Easing.in(Easing.cubic),
  });

  // Send button
  const sendLive = spring({
    frame: frame - SEND_ACTIVE,
    fps,
    config: {damping: 11, stiffness: 160, mass: 0.6},
  });
  const clickDip = interpolate(
    frame,
    [SEND_CLICK, SEND_CLICK + 3, SEND_CLICK + 7],
    [1, 0.84, 1],
    {extrapolateLeft: 'clamp', extrapolateRight: 'clamp'}
  );
  const clickRing = interpolate(frame, [SEND_CLICK, SEND_CLICK + 16], [0, 1], {
    extrapolateLeft: 'clamp',
    extrapolateRight: 'clamp',
  });
  const sendActive = frame >= SEND_ACTIVE && frame < FLY + 8;
  const sendPulse = sendActive
    ? 1 + 0.045 * Math.sin((frame - SEND_ACTIVE) * 0.28)
    : 1;

  // Agent typing dots after send
  const dotsIn = interpolate(frame, [DOTS, DOTS + 8], [0, 1], {
    extrapolateLeft: 'clamp',
    extrapolateRight: 'clamp',
  });

  return (
    <AbsoluteFill>
      <Keycap frame={frame} fps={fps} />

      <div
        style={{
          position: 'absolute',
          top: 148,
          left: 0,
          right: 0,
          textAlign: 'center',
          fontFamily: FONT,
          fontSize: 16,
          fontWeight: 700,
          letterSpacing: '0.3em',
          color: C.text3,
          opacity: caption.o,
        }}
      >
        {caption.t}
      </div>

      <AbsoluteFill style={{alignItems: 'center', justifyContent: 'center'}}>
        <div
          style={{
            width: BOX_W,
            height: boxH,
            transform: `translateY(${(1 - boxIn) * 40 - 30}px)`,
            opacity: boxIn * exit,
            position: 'relative',
            backgroundColor: '#FFFFFF',
            borderRadius: 18,
            border: `1px solid ${C.border}`,
            boxShadow:
              '0 24px 60px rgba(28,30,33,0.10), 0 3px 10px rgba(28,30,33,0.05)',
          }}
        >
          {/* Placeholder */}
          <div
            style={{
              position: 'absolute',
              top: 24,
              left: 28,
              fontFamily: FONT,
              fontSize: 27,
              fontWeight: 400,
              color: C.disabled,
              opacity: placeholderOpacity,
            }}
          >
            Message your coding agent…
          </div>

          {/* Spoken words, typed into the box */}
          <div
            style={{
              position: 'absolute',
              top: 22,
              left: 28,
              right: 28,
              display: 'flex',
              flexWrap: 'wrap',
              alignItems: 'baseline',
              fontFamily: FONT,
              fontSize: 27,
              fontWeight: 500,
              lineHeight: 1.5,
              filter: `blur(${dim * 2.5}px)`,
            }}
          >
            {WORDS.map((w, i) => {
              const start = wordStarts[i];
              if (frame < start) return null;

              const pop = spring({
                frame: frame - start,
                fps,
                config: {damping: 14, stiffness: 200, mass: 0.6},
              });

              const fallDelay = w.filler
                ? random(`f${i}`) * 4
                : 4 + random(`k${i}`) * 9;
              const fallT = interpolate(
                frame,
                [FALL + fallDelay, FALL + fallDelay + 14],
                [0, 1],
                {
                  extrapolateLeft: 'clamp',
                  extrapolateRight: 'clamp',
                  easing: Easing.in(Easing.quad),
                }
              );

              const y = w.filler
                ? (1 - pop) * 12 + fallT * 130
                : (1 - pop) * 12 - fallT * 46;
              const rot = w.filler ? fallT * (i % 2 ? 14 : -12) : 0;

              return (
                <span
                  key={i}
                  style={{
                    display: 'inline-block',
                    marginRight: 10,
                    color: w.filler ? C.text3 : C.text,
                    fontStyle: w.filler ? 'italic' : 'normal',
                    opacity: pop * (1 - fallT) * (1 - dim * 0.3),
                    transform: `translateY(${y}px) rotate(${rot}deg) scale(${
                      0.86 + 0.14 * pop - (w.filler ? 0 : fallT * 0.05)
                    })`,
                  }}
                >
                  {w.t}
                </span>
              );
            })}
            {listening && lastVisible >= 0 && (
              <span
                style={{
                  display: 'inline-block',
                  width: 3.5,
                  height: 28,
                  borderRadius: 2,
                  marginLeft: 1,
                  backgroundColor: C.primary,
                  opacity: caretBlink,
                  transform: 'translateY(5px)',
                }}
              />
            )}
          </div>

          {/* The polished prompt, replacing the text in place */}
          <div
            style={{
              position: 'absolute',
              top: 24,
              left: 28,
              right: 28,
              fontFamily: MONO,
              fontSize: 14.5,
              opacity: 1 - flyT,
              transform: `translateY(${flyT * -420}px) scale(${1 - flyT * 0.04})`,
            }}
          >
            {LINES.map((line, i) => {
              const start = CASCADE + i * STAGGER;
              if (frame < start) return null;
              const t = interpolate(frame, [start, start + 8], [0, 1], {
                extrapolateLeft: 'clamp',
                extrapolateRight: 'clamp',
              });
              const height =
                line.kind === 'h1' ? 34 : line.kind === 'h2' ? 28 : line.kind === 'blank' ? 10 : 24;
              return (
                <div
                  key={i}
                  style={{
                    display: 'flex',
                    alignItems: 'baseline',
                    height,
                    opacity: t,
                    transform: `translateY(${(1 - t) * 8}px)`,
                  }}
                >
                  <Syntax line={line} />
                </div>
              );
            })}
          </div>

          {/* Agent typing dots after the prompt is sent — a reply bubble above the box */}
          <div
            style={{
              position: 'absolute',
              top: -66,
              left: 4,
              display: 'flex',
              alignItems: 'center',
              gap: 5,
              backgroundColor: C.elevated,
              borderRadius: 16,
              padding: '11px 15px',
              opacity: dotsIn,
              transform: `translateY(${(1 - dotsIn) * 10}px)`,
            }}
          >
            {[0, 1, 2].map((i) => {
              const phase = (Math.sin((frame - DOTS) * 0.32 - i * 1.05) + 1) / 2;
              return (
                <div
                  key={i}
                  style={{
                    width: 7,
                    height: 7,
                    borderRadius: 4,
                    backgroundColor: C.text3,
                    opacity: 0.4 + 0.6 * phase,
                    transform: `translateY(${-2.5 * phase}px)`,
                  }}
                />
              );
            })}
          </div>

          {/* Composer bottom row */}
          <div
            style={{
              position: 'absolute',
              left: 20,
              right: 16,
              bottom: 13,
              display: 'flex',
              alignItems: 'center',
              gap: 14,
            }}
          >
            <PlusIcon />
            <SmallMic active={listening && frame > 20} />
            <div style={{marginLeft: 'auto', position: 'relative'}}>
              <div
                style={{
                  position: 'absolute',
                  left: '50%',
                  top: '50%',
                  width: 44 + clickRing * 46,
                  height: 44 + clickRing * 46,
                  borderRadius: 999,
                  border: `2px solid ${C.primary}`,
                  opacity: clickRing > 0 ? (1 - clickRing) * 0.8 : 0,
                  transform: 'translate(-50%, -50%)',
                }}
              />
              <div
                style={{
                  width: 44,
                  height: 44,
                  borderRadius: 999,
                  display: 'flex',
                  alignItems: 'center',
                  justifyContent: 'center',
                  backgroundColor: sendActive ? C.primary : C.elevated,
                  boxShadow: sendActive
                    ? `0 6px 20px rgba(74,158,255,${0.45 * sendLive})`
                    : 'none',
                  transform: `scale(${(0.94 + 0.06 * (sendActive ? sendLive : 1)) * sendPulse * clickDip})`,
                }}
              >
                <SendArrow color={sendActive ? '#FFFFFF' : C.disabled} />
              </div>
            </div>
          </div>
        </div>
      </AbsoluteFill>
    </AbsoluteFill>
  );
};
