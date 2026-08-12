const { test } = require('node:test')
const assert = require('node:assert')
const { classify, buttonFor, changeLines } = require('../logic.js')

const ready = {
  schema: 2, state: 'ready', checked_at: '2026-08-11T06:41:49-06:00',
  warnings: [], blockers: [], reboot_recommended: false, reboot_reason: [],
  changes: [{ name: 'nixpkgs', kind: 'input', from: 'abc1234', to: 'def5678' }],
  closure_diff: { added: [], removed: [], changed: [], size_delta_mb: 1.5 },
}

test('a ready update offers to apply', () => {
  const b = buttonFor(ready)
  assert.equal(b.action, 'apply')
  assert.equal(b.enabled, true)
})

test('a reboot-recommended update offers boot, never switch', () => {
  const b = buttonFor({ ...ready, reboot_recommended: true, reboot_reason: ['nvidia-open'] })
  assert.equal(b.action, 'apply-boot')
})

test('ready with warnings is visually distinct from ready without', () => {
  const clean = classify(ready)
  const warned = classify({ ...ready, warnings: [{ code: 'x', detail: 'y' }] })
  assert.notEqual(clean.tone, warned.tone)
})

test('a blocker disables the button and says why', () => {
  const b = buttonFor({ ...ready, blockers: [{ code: 'dirty_tree', detail: 'el arbol de trabajo tiene cambios sin commitear' }] })
  assert.equal(b.enabled, false)
  assert.match(b.reason, /sin commitear/)
})

test('an unknown schema is unknown, never healthy', () => {
  const c = classify({ schema: 99, state: 'ready' })
  assert.equal(c.tone, 'unknown')
  assert.notEqual(c.tone, 'ok')
})

test('a null status is unknown, never up to date', () => {
  // The failure that matters: upd not on PATH, the state dir unreadable, the
  // process killed. Rendering that as "todo al dia" would recreate, in the most
  // visible place on the screen, the exact failure the engine exists to remove.
  const c = classify(null)
  assert.equal(c.tone, 'unknown')
})

test('build_failed is an error, not a ready', () => {
  assert.equal(classify({ ...ready, state: 'build_failed' }).tone, 'error')
})

test('changeLines skips entries whose version did not move', () => {
  const lines = changeLines({ ...ready, changes: [
    ...ready.changes,
    { name: 'brave-origin', kind: 'local_pkg', from: '1.93.134', to: '1.93.134' },
  ]})
  assert.equal(lines.length, 1)
  assert.equal(lines[0].name, 'nixpkgs')
})

test('changeLines renders an added and a removed package readably', () => {
  const lines = changeLines({ ...ready, changes: [
    { name: 'nuevo', kind: 'input', from: '', to: 'abc1234' },
  ]})
  assert.match(lines[0].text, /abc1234/)
})

// ---------------------------------------------------------------------------
// Below this line: the measured contract, not the one the plan assumed.
//
// The two fixtures are the real output of the two sources on this machine,
// captured on 2026-08-11 and identical except for one key. `upd status --json`
// carries `blockers`; /var/lib/nixos-upd/status.json does not and by design
// never will -- lib/blockers.sh opens with the reason, that a dirty tree and a
// checked-out branch are facts about *now* and the nightly run cannot write
// them down hours in advance.
// ---------------------------------------------------------------------------

const live = require('./fixtures/status-live-ready.json')
const onDisk = require('./fixtures/status-ondisk-ready.json')

test('the two real sources differ only in blockers, which is why the rest of this holds', () => {
  // Guards the premise of the tests underneath. If a future schema makes the
  // two files diverge somewhere else, this fails first and says so, instead of
  // letting the blockers tests quietly stop testing what they claim to.
  const { blockers, ...liveRest } = live
  assert.ok(Array.isArray(blockers), 'upd status --json debe traer blockers')
  assert.equal(Object.hasOwn(onDisk, 'blockers'), false, 'status.json no lleva blockers')
  assert.deepEqual(liveRest, onDisk)
})

test('a live status with blockers disables the button and names every one of them', () => {
  // Two real blockers, because this repo is on a feature branch with the work
  // in progress uncommitted -- the ordinary state of a machine being worked on.
  const b = buttonFor(live)
  assert.equal(b.enabled, false)
  assert.equal(b.action, 'none')
  assert.match(b.reason, /sin commitear/)
  assert.match(b.reason, /upd-barra/)
})

test('a blocker detail is passed through verbatim, never reworded', () => {
  // The decision written down before this task: `pending_reboot` disables the
  // panel button but does not stop `upd apply` from a terminal, so its wording
  // must not say "no puedo". The engine owns that sentence; this only shows it.
  const detail = 'el perfil del sistema y el sistema en marcha no son la misma generacion (un apply sin reiniciar, o un `test` sin fijar); resuelvelo antes de apilar otra actualizacion encima'
  const b = buttonFor({ ...ready, blockers: [{ code: 'pending_reboot', detail }] })
  assert.equal(b.reason, detail)
})

test('an unknown blocker code still disables and still shows its detail', () => {
  // blockers.sh states this outright: the vocabulary went from four codes to
  // six while it was being written and can grow again, so a consumer must not
  // skip a code it does not recognise.
  const b = buttonFor({ ...ready, blockers: [{ code: 'inventado_manana', detail: 'algo nuevo lo impide' }] })
  assert.equal(b.enabled, false)
  assert.match(b.reason, /algo nuevo lo impide/)
})

test('a status with no blockers list never offers to apply', () => {
  // The hazard the fixtures expose. Read from status.json instead of from
  // `upd status --json` -- a fallback when upd is not on PATH is the obvious
  // way to get there -- and the blockers are not missing because there are
  // none, they are missing because nobody computed them. Defaulting that to
  // "nothing in the way" draws a live Aplicar button over a tree the engine
  // will refuse, which is the same failure as rendering an unreadable state as
  // healthy, one step further along.
  const b = buttonFor(onDisk)
  assert.equal(b.enabled, false)
  assert.notEqual(b.action, 'apply')
  assert.notEqual(b.action, 'apply-boot')
})

test('a warnings field that is not a list is not a clean run', () => {
  // upd.sh's own reader already decided this: `if type == "array" then length
  // else 1` -- a present-but-malformed warnings counts as one finding and the
  // report says the file is suspect. The panel agreeing costs nothing and
  // stops a producer bug from rendering as an all-clear.
  const clean = classify(ready)
  const broken = classify({ ...ready, warnings: { code: 'x' } })
  assert.notEqual(broken.tone, clean.tone)
})

test('an absent warnings field is not itself a warning', () => {
  // The other half of `(.warnings // [])`: absent and null mean zero, and only
  // a present non-array means "suspect". Without this the rule above would
  // creep into flagging every state that simply has nothing to say.
  assert.equal(classify({ ...ready, warnings: undefined }).tone, classify(ready).tone)
  assert.equal(classify({ ...ready, warnings: null }).tone, classify(ready).tone)
})

test('the real ready status summarises the changes a human would count', () => {
  // Seven entries in `changes`, one of which (brave-origin) is a local package
  // whose version did not move. The panel must show six.
  const c = classify(live)
  assert.equal(c.state, 'ready')
  assert.equal(changeLines(live).length, 6)
  assert.match(c.summary, /^6 /)
  assert.equal(changeLines(live).some(l => l.name === 'brave-origin'), false)
})

test('a reboot-recommended real status says which packages asked for it', () => {
  // reboot_reason on this machine: the kernel and the NVIDIA pair. The button
  // is the one place the user finds out why they are being sent to a reboot
  // rather than a switch.
  const b = buttonFor({ ...live, blockers: [] })
  assert.equal(b.action, 'apply-boot')
  assert.match(b.reason, /nvidia-open/)
  assert.match(b.reason, /linux-xanmod/)
})
