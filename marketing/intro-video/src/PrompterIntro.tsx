import {AbsoluteFill, Sequence} from 'remotion';
import {Background} from './Background';
import {HUDPill} from './HUDPill';
import {Intro} from './scenes/Intro';
import {ComposerDemo} from './scenes/ComposerDemo';
import {Outro} from './scenes/Outro';

// Global timeline @30fps (~20s total):
//   0–60    brand sting: the ambitious prompts lockup
//   52–466  the full demo, inside an AI composer: dictate → transform → send
//   74–386  HUD pill layer (listening → crafting → pasted)
//   464–614 end card: lockup, tagline, real usage stats
const T = {
  intro: {from: 0, dur: 60},
  composer: {from: 52, dur: 414},
  pill: {from: 74, dur: 312},
  pillProcessing: 240,
  pillSuccess: 288,
  pillFade: 368,
  outro: {from: 464, dur: 150},
};

export const TOTAL_DURATION = 614;

export const PrompterIntro: React.FC = () => {
  return (
    <AbsoluteFill>
      <Background />
      <Sequence from={T.intro.from} durationInFrames={T.intro.dur}>
        <Intro />
      </Sequence>
      <Sequence from={T.composer.from} durationInFrames={T.composer.dur}>
        <ComposerDemo sceneDuration={T.composer.dur} />
      </Sequence>
      <Sequence from={T.pill.from} durationInFrames={T.pill.dur}>
        <HUDPill
          processingAt={T.pillProcessing - T.pill.from}
          successAt={T.pillSuccess - T.pill.from}
          fadeAt={T.pillFade - T.pill.from}
        />
      </Sequence>
      <Sequence from={T.outro.from} durationInFrames={T.outro.dur}>
        <Outro />
      </Sequence>
    </AbsoluteFill>
  );
};
