"""Regression of the current large-swipe gate, not the historical hold gesture."""
from pathlib import Path
import sys,unittest,json
from types import SimpleNamespace
S=Path(sys.argv[1]) if len(sys.argv)>1 else Path('D:/M7_STUDIO_PC_R6_1_VIDEO_FIX')
sys.argv=sys.argv[:1];sys.path.insert(0,str(S/'PC_VIEWER'))
from gesture_engine import SwipeGate,palm_position,decode_frame
class CurrentGestureTests(unittest.TestCase):
 def test_static_hand_and_small_jitter_do_not_fire(self):
  g=SwipeGate();self.assertEqual(sum(g.update(.5+(i%2)*.015,i*.1) for i in range(40)),0)
 def test_large_swipe_both_directions(self):
  for positions in [[.2,.3,.45],[.75,.65,.5]]:
   g=SwipeGate();self.assertEqual([g.update(x,t*.15) for t,x in enumerate(positions)],[False,False,True])
 def test_swipe_not_repeated_until_release_and_cooldown(self):
  g=SwipeGate()
  self.assertEqual(sum(g.update(x,t*.15) for t,x in enumerate([.2,.3,.45])),1)
  self.assertFalse(g.update(.7,3.2));self.assertFalse(g.update(None,3.3));self.assertFalse(g.update(None,4.2))
  self.assertEqual(sum(g.update(x,4.4+t*.15) for t,x in enumerate([.75,.65,.5])),1)
 def test_brief_dropout_keeps_motion(self):
  g=SwipeGate();self.assertFalse(g.update(.2,0));self.assertFalse(g.update(.3,.15));self.assertFalse(g.update(None,.2));self.assertTrue(g.update(.45,.45))
 def test_random_back_and_forth_does_not_fire(self):
  g=SwipeGate();self.assertEqual(sum(g.update(x,i*.1) for i,x in enumerate([.4,.55,.4,.55,.4,.58,.4])),0)
 def test_palm_open_closed_and_short_list(self):
  p=json.loads((S/'tests/GESTURE_REFERENCE_RESULT.json').read_text())['hands'][0]['landmarks']
  def lm(a):return [SimpleNamespace(x=v[0],y=v[1]) for v in a]
  self.assertIsNotNone(palm_position(lm(p),640,360))
  q=[a[:] for a in p]
  for tip in [8,12,16,20]:q[tip]=q[0][:]
  self.assertIsNone(palm_position(lm(q),640,360));self.assertIsNone(palm_position(lm(p[:4]),640,360))
 def test_rgb565_and_rgb888_frame_decode(self):
  import numpy as np
  a=decode_frame({'height':1,'width':3,'format':1,'data':bytes.fromhex('00f8e0071f00')})
  np.testing.assert_array_equal(a,np.array([[[255,0,0],[0,255,0],[0,0,255]]],np.uint8))
  b=decode_frame({'height':1,'width':1,'format':0,'data':bytes([1,2,3])});np.testing.assert_array_equal(b,[[[1,2,3]]])
if __name__=='__main__':unittest.main(verbosity=2)
