import {AbsoluteFill, useCurrentFrame} from 'remotion';
import {C} from './theme';

export const Background: React.FC = () => {
  const frame = useCurrentFrame();
  const driftX = Math.sin(frame * 0.006) * 40;
  const driftY = Math.cos(frame * 0.004) * 30;

  return (
    <AbsoluteFill style={{backgroundColor: C.bg}}>
      <AbsoluteFill
        style={{
          background:
            'radial-gradient(120% 90% at 50% 110%, #F2F6FC 0%, #FAFBFD 45%, #FFFFFF 100%)',
        }}
      />
      <div
        style={{
          position: 'absolute',
          width: 1300,
          height: 850,
          left: 1000 + driftX,
          top: -340 + driftY,
          background:
            'radial-gradient(50% 50% at 50% 50%, rgba(74,158,255,0.08) 0%, rgba(74,158,255,0) 70%)',
        }}
      />
      <div
        style={{
          position: 'absolute',
          width: 1100,
          height: 950,
          left: -420 - driftX,
          top: 280 - driftY,
          background:
            'radial-gradient(50% 50% at 50% 50%, rgba(88,86,214,0.05) 0%, rgba(88,86,214,0) 70%)',
        }}
      />
    </AbsoluteFill>
  );
};
