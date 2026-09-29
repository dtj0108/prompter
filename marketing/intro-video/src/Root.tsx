import {Composition} from 'remotion';
import {PrompterIntro, TOTAL_DURATION} from './PrompterIntro';

export const Root: React.FC = () => {
  return (
    <Composition
      id="PrompterIntro"
      component={PrompterIntro}
      durationInFrames={TOTAL_DURATION}
      fps={30}
      width={1920}
      height={1080}
    />
  );
};
