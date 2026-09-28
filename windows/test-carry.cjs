// Run with node --test test-carry.cjs from windows/.
// The carry overlay's own arithmetic: the spring the notch follows the hand on, and the border it
// travels. The Mac's FollowSpringTests and BorderTrackTests, against carry.html's script.
const { readFileSync } = require('node:fs');
const { join } = require('node:path');
const vm = require('node:vm');
const assert = require('node:assert/strict');
const { test } = require('node:test');

const html = readFileSync(join(__dirname, 'codenotch/ui/carry.html'), 'utf8');
const script = html.match(/<script>([\s\S]*?)<\/script>/)[1];

function page() {
  const element = () => ({ style: {}, children: [], setAttribute() {}, querySelector: () => element(), set innerHTML(_) {} });
  const context = vm.createContext({
    window: { __TAURI__: { core: { invoke: () => Promise.resolve(null) }, event: { listen: () => Promise.resolve() } } },
    document: { getElementById: element },
    matchMedia: () => ({ matches: false }),
    requestAnimationFrame() {},
    Math,
  });
  vm.runInContext(script, context);
  vm.runInContext(`st = { w: 1800, h: 1169, reach: 325, size: 1, edge: 'top', shape: {
    radius: 20, fillet: 38.7,
    upright: { depth: 70, length: 300, pitch: 84, inset: 34.5 },
    flat: { depth: 95, length: 200, pitch: 58, inset: 47.5 },
  } }`, context);
  return (source) => vm.runInContext(source, context);
}

test('following the hand is brisk and all but dead; coming to rest gives a little and settles', () => {
  const run = page();
  const follow = (spring, fps) => run(`(() => {
    const target = 100, dt = 1 / ${fps};
    let position = 0, velocity = 0, furthest = 0, settledBy = null;
    for (let frame = 0; frame < ${fps} * 2; frame++) {
      const step = spring(target - position, velocity, dt, ${spring});
      position += step.moved; velocity = step.velocity;
      furthest = Math.max(furthest, position);
      if (settledBy === null && Math.abs(target - position) < .3 && Math.abs(velocity) < 6) settledBy = (frame + 1) * dt;
    }
    return { overshoot: furthest - target, settledBy };
  })()`);
  for (const fps of [60, 120]) {
    const hand = follow('FOLLOW', fps);
    assert.ok(hand.overshoot < 2, `${fps}fps: it swings past the hand`);
    assert.ok(hand.settledBy !== null && hand.settledBy < .5, `${fps}fps: it lags the hand`);
    const rest = follow('SETTLE', fps);
    assert.ok(rest.overshoot > .1, `${fps}fps: no give at all`);
    assert.ok(rest.overshoot < 5, `${fps}fps: it wobbles`);
    assert.ok(rest.settledBy !== null && rest.settledBy < .8, `${fps}fps: it never settles`);
  }
});

test('every place is on one edge and back, round the whole border', () => {
  const run = page();
  for (const [edge, along] of [['top', 400], ['right', 300], ['bottom', 700], ['left', 900]]) {
    const [back, at] = run(`placeAt(positionOn('${edge}', ${along}))`);
    assert.equal(back, edge);
    assert.ok(Math.abs(at - along) < .001, `${edge} ${along} came back as ${at}`);
  }
  const perimeter = run('perimeter()');
  assert.ok(Math.abs(run('wrap(-10)') - (perimeter - 10)) < .001);
  assert.ok(Math.abs(run('signed(perimeter() - 10)') + 10) < .001, 'just behind the start is a step back');
});

test('it comes to rest where its window can be put down', () => {
  const run = page();
  // The window is 650 long and kept in the work area, so the notch's middle stays 325 from an end
  assert.deepEqual(JSON.parse(run(`JSON.stringify(placeAt(resting(positionOn('right', 40))))`)), ['right', 325]);
  assert.deepEqual(JSON.parse(run(`JSON.stringify(placeAt(resting(positionOn('top', 1790))))`)), ['top', 1800 - 325]);
  assert.deepEqual(JSON.parse(run(`JSON.stringify(placeAt(resting(positionOn('left', 600))))`)), ['left', 600], 'clear of the ends it stays put');
});

test('the drawing is turned over on the left and bottom edges, so its flares still curve outward', () => {
  const run = page();
  const sweeps = (edge) => [...run(`notchPath('${edge}', 300, 500, 70, 20, 38.7)`).matchAll(/A[\d.]+ [\d.]+ 0 0 (\d)/g)].map((m) => m[1]).join('');
  assert.equal(sweeps('right'), '1001');
  assert.equal(sweeps('top'), '1001');
  assert.equal(sweeps('left'), '0110');
  assert.equal(sweeps('bottom'), '0110');
});
