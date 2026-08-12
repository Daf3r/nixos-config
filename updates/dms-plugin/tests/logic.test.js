const { test } = require('node:test')
const assert = require('node:assert')
const { classify, buttonFor, checkFor, changeLines } = require('../logic.js')

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
  // Rewritten from the plan's version, which built only the added package and
  // then asserted `/abc1234/` on it -- so the name promised two cases and the
  // body covered one, and `(nuevo)` and `(fuera)` could both vanish with the
  // suite still green. The vice this branch keeps finding, in a test of my own.
  const [added, removed] = changeLines({ ...ready, changes: [
    { name: 'nuevo', kind: 'input', from: '', to: 'abc1234' },
    { name: 'retirado', kind: 'local_pkg', from: '1.93.134', to: '' },
  ]})
  assert.equal(added.name, 'nuevo')
  assert.match(added.text, /abc1234/)
  assert.match(added.text, /\(nuevo\)/, 'una entrada sin origen tiene que decir que es nueva')
  assert.equal(removed.name, 'retirado')
  assert.match(removed.text, /1\.93\.134/)
  assert.match(removed.text, /\(fuera\)/, 'una entrada sin destino tiene que decir que se va')
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

// ---------------------------------------------------------------------------
// The other four terminal states. The first round of this suite tested `ready`
// deeply and left `current`, `check_failed` and the unknown-state branch with
// no test at all, and `build_failed` with only its tone -- so `buttonFor` was
// never once called with anything but a `ready`. Eight mutants lived in that
// gap, including a live "Aplicar" over an update that does not compile.
// ---------------------------------------------------------------------------

test('no state other than ready ever offers to apply', () => {
  // The worst of the survivors: turning the non-ready button into an enabled
  // `apply` passed the whole suite. An Aplicar over a `build_failed` is an
  // offer to switch to a system that failed to build.
  for (const state of ['current', 'build_failed', 'check_failed']) {
    const b = buttonFor({ ...ready, state })
    assert.equal(b.action, 'check', `${state} deberia ofrecer comprobar`)
    assert.equal(b.enabled, true, `${state} deberia dejar comprobar`)
    assert.notEqual(b.label, 'Aplicar')
  }
})

// ---------------------------------------------------------------------------
// `engine_running` outside the ready branch.
//
// The gap this closes, measured before it was closed: `blockers` was only ever
// read inside the `ready` branch, so a `current` status taken while the engine
// held the lock drew a live "Comprobar ahora". The blocker was right there in
// the same document, and the button ignored it.
// ---------------------------------------------------------------------------

const enMarcha = { code: 'engine_running', detail: 'hay una comprobacion en marcha ahora mismo; espera a que termine' }

test('with the engine holding the lock, no state offers to check', () => {
  // Every state that reaches the check button, not just the one that is easy
  // to reach: `current` is the ordinary morning state, and the two failures are
  // exactly when a user reaches for "comprobar otra vez".
  for (const state of ['current', 'build_failed', 'check_failed']) {
    const b = buttonFor({ ...ready, state, blockers: [enMarcha] })
    assert.equal(b.enabled, false, `${state}: el motor esta corriendo, el boton no puede estar vivo`)
    assert.equal(b.action, 'none', `${state}: no puede quedar una accion que el motor va a rechazar`)
  }
})

test('the disabled check button says the engine is busy, in the engine words', () => {
  // Same contract as the blockers on the apply side: the sentence belongs to
  // blockers.sh and this only shows it. A second wording here would be a second
  // description of the same refusal, drifting from the first.
  const b = buttonFor({ ...ready, state: 'current', blockers: [enMarcha] })
  assert.equal(b.reason, enMarcha.detail)
  assert.equal(b.label, 'Comprobar ahora', 'la etiqueta sigue nombrando la operacion; lo apagado es el boton')
})

test('engine_running is found wherever it sits in the list, not only first', () => {
  // The ordering is not hypothetical and it is not favourable: blockers.sh
  // appends the two git facts before it ever looks at the lock, so on a machine
  // somebody is working on -- dirty tree, feature branch -- `engine_running` is
  // the third entry and never the first.
  //
  // Every other case in this section hands the function a one-element list, and
  // that is what made them all agree with a reader that only ever inspected
  // `blockers[0]`. Measured: replacing the `find` with a guarded
  // `status.blockers[0].code === 'engine_running'` passed all 41 tests, and the
  // defect it leaves is precisely the one this branch exists to prevent -- a
  // live "Comprobar ahora" over an engine that holds the lock.
  const b = buttonFor({ ...ready, state: 'current', blockers: [
    { code: 'dirty_tree', detail: 'el arbol de trabajo tiene cambios sin commitear' },
    { code: 'wrong_branch', detail: "esta en la rama 'upd-barra' y el motor prepara desde 'main'" },
    enMarcha,
  ]})
  assert.equal(b.enabled, false, 'el motor esta corriendo aunque no encabece la lista')
  assert.equal(b.action, 'none')
  // Solo el del lock: los otros dos paran un apply y no dicen nada de una
  // comprobacion, asi que citarlos aqui seria darle al usuario dos motivos de
  // los cuales uno no lo es.
  assert.equal(b.reason, enMarcha.detail)
})

test('an engine_running with no detail still explains why checking is off', () => {
  const b = buttonFor({ ...ready, state: 'current', blockers: [{ code: 'engine_running' }] })
  assert.equal(b.enabled, false)
  assert.match(b.reason, /engine_running/)
  assert.match(b.reason, /upd status/)
})

test('the blockers that only stop an apply do not stop a check', () => {
  // The other half of the rule, and the one that keeps this from creeping into
  // "any blocker kills every button". None of these three has anything to say
  // about running a check, and a dead "Comprobar ahora" over a machine that
  // would have checked fine is a worse answer than no rule at all.
  for (const code of ['dirty_tree', 'wrong_branch', 'pending_reboot']) {
    const b = buttonFor({ ...ready, state: 'current', blockers: [{ code, detail: 'da igual lo que diga' }] })
    assert.equal(b.action, 'check', `${code} no impide comprobar`)
    assert.equal(b.enabled, true, `${code} no impide comprobar`)
  }
})

test('a non-ready status with no blockers list still offers to check', () => {
  // Deliberately the opposite answer from the `ready` branch on the same input,
  // and pinned here so nobody makes the two "consistent" by accident. On the
  // apply side an absent list means nobody asked, and guessing draws an Aplicar
  // the engine refuses. On the check side guessing the other way draws a dead
  // button over a machine where checking works, which is the worse of the two.
  const b = buttonFor({ ...onDisk, state: 'current' })
  assert.equal(b.action, 'check')
  assert.equal(b.enabled, true)
})

test('a ready with the engine running still talks about applying, not checking', () => {
  // The regression this invites: hoisting the engine_running test above the
  // state dispatch. It would answer "Comprobar ahora" for a ready update, and
  // it would drop the other blockers from the sentence -- a user told only
  // about the lock, who waits for it to clear and finds the button still dead
  // for the dirty tree nobody mentioned.
  const b = buttonFor({ ...ready, blockers: [
    { code: 'dirty_tree', detail: 'el arbol de trabajo tiene cambios sin commitear' },
    enMarcha,
  ]})
  assert.equal(b.label, 'Aplicar')
  assert.equal(b.enabled, false)
  assert.match(b.reason, /sin commitear/)
  assert.match(b.reason, /en marcha/)
})

test('a clean current is the only state that reads as ok', () => {
  const c = classify({ ...ready, state: 'current' })
  assert.equal(c.tone, 'ok')
  assert.equal(c.summary, 'todo al dia')
})

test('current with warnings is visually distinct from current without', () => {
  // The morning state, and the one a user reads fastest. Pinning only the
  // `ready` half of this rule left `current` free to paint findings as clean.
  const clean = classify({ ...ready, state: 'current' })
  const warned = classify({ ...ready, state: 'current', warnings: [{ code: 'x', detail: 'y' }] })
  assert.equal(clean.tone, 'ok')
  assert.notEqual(warned.tone, 'ok')
})

test('check_failed is an error and shows what the engine said', () => {
  const c = classify({ ...ready, state: 'check_failed', error: 'no pude escribir el diff' })
  assert.equal(c.tone, 'error')
  assert.notEqual(c.tone, 'ok')
  assert.match(c.summary, /no pude escribir el diff/)
})

test('check_failed with no error message is still an error', () => {
  const c = classify({ ...ready, state: 'check_failed' })
  assert.equal(c.tone, 'error')
  assert.ok(c.summary.length > 0, 'un fallo sin mensaje sigue necesitando una linea')
})

test('a state this plugin does not know is unknown, never ok', () => {
  // The third axis, and the one that was missing: the suite covered an unknown
  // `schema` and a null status, never an unknown `state`. It is not
  // hypothetical -- upd.sh reserves exit 2 for a status.json carrying a state
  // its reader does not know, so the two readers can meet the same file.
  const c = classify({ ...ready, state: 'reticulando_splines' })
  assert.equal(c.tone, 'unknown')
  assert.notEqual(c.tone, 'ok')
  assert.match(c.summary, /reticulando_splines/)
})

test('an unknown state offers no button that acts on it', () => {
  const b = buttonFor({ ...ready, state: 'reticulando_splines' })
  assert.equal(b.enabled, false)
  assert.equal(b.action, 'none')
})

// ---------------------------------------------------------------------------
// Malformed input from the producer, on the two fields that drive the button.
// ---------------------------------------------------------------------------

test('a blocker with no detail still explains why the button is dead', () => {
  // blockers.sh:80-84 makes the detail the whole message for a human -- what
  // the panel puts next to the disabled button. If it arrives empty the button
  // must not go quiet: a dead Aplicar with no reason is the one outcome a user
  // cannot act on, and cannot even report.
  const b = buttonFor({ ...ready, blockers: [{ code: 'dirty_tree' }] })
  assert.equal(b.enabled, false)
  assert.ok(b.reason.length > 0, 'un boton apagado sin motivo no se puede ni reportar')
  assert.match(b.reason, /dirty_tree/)
})

test('a blocker with neither code nor detail still explains itself', () => {
  // Tightened: `length > 0` was satisfied by any string at all, including one
  // that says nothing. With no code and no detail there is nothing true left to
  // say about *this* blocker, so what the line owes the user is the admission
  // and somewhere to go -- the same `upd status` its sibling above points at.
  const b = buttonFor({ ...ready, blockers: [{}] })
  assert.equal(b.enabled, false)
  assert.match(b.reason, /sin codigo/)
  assert.match(b.reason, /upd status/)
})

test('warnings false is not a warning, because jq reads it as absent', () => {
  // jq's `//` catches false as well as null, so `(.warnings // [])` on a false
  // counts zero. Claiming to copy the shell's rule and then diverging on the
  // one value nobody tests is how two readers drift apart.
  assert.equal(classify({ ...ready, warnings: false }).tone, classify(ready).tone)
})

test('a reboot with no reasons given does not trail an empty list', () => {
  const b = buttonFor({ ...ready, reboot_recommended: true, reboot_reason: [] })
  assert.equal(b.action, 'apply-boot')
  assert.doesNotMatch(b.reason, /:\s*$/, 'un motivo cortado en dos puntos parece un fallo de la app')
})

// ---------------------------------------------------------------------------
// What the user actually reads, anchored in absolute values.
//
// Everything above pinned decisions -- which action, enabled or not. These pin
// the four fields the panel paints: the summary sentence, the tone, the icon
// and the button label. A suite that checks only decisions lets the module keep
// deciding right and start *saying* something false, which is the same bug from
// the one seat that matters.
// ---------------------------------------------------------------------------

test('every state says something true about itself', () => {
  // build_failed had its tone pinned and its sentence loose, so the summary
  // could read "todo al dia" over an update that does not compile while the
  // tone stayed 'error'. The tone colours a dot; this is the line a human
  // reads.
  const summaryOf = s => classify(s).summary
  assert.match(summaryOf({ ...ready, state: 'build_failed' }), /NO compila/)
  assert.doesNotMatch(summaryOf({ ...ready, state: 'build_failed' }), /todo al dia/)
  assert.equal(summaryOf({ ...ready, state: 'current' }), 'todo al dia')
  assert.match(summaryOf(ready), /^1 cambios/)
  assert.match(summaryOf({ ...ready, state: 'check_failed', error: 'no pude clonar' }), /no pude clonar/)
  assert.doesNotMatch(summaryOf({ ...ready, state: 'check_failed' }), /todo al dia/)
})

test('the tone of a ready is not merely different when warned, it is the right way round', () => {
  // The plan's test asked only for `notEqual`, and a swapped pair is also
  // unequal: a clean ready painted as a warning and a warned one as clean
  // passes that assertion perfectly.
  assert.equal(classify(ready).tone, 'ready')
  assert.equal(classify({ ...ready, warnings: [{ code: 'x', detail: 'y' }] }).tone, 'warn')
})

test('each state carries its own icon', () => {
  // In a bar widget the icon is the whole of what is visible without opening
  // the panel -- the most seen field in this module, and until now the only one
  // with no assertion anywhere.
  const iconOf = s => classify(s).icon
  assert.equal(iconOf({ ...ready, state: 'current' }), 'check_circle')
  assert.equal(iconOf(ready), 'system_update_alt')
  assert.equal(iconOf({ ...ready, state: 'build_failed' }), 'error')
  assert.equal(iconOf({ ...ready, state: 'check_failed' }), 'error')
  assert.equal(iconOf({ ...ready, state: 'reticulando_splines' }), 'help')
  assert.equal(iconOf({ schema: 99, state: 'ready' }), 'help')
  assert.equal(iconOf(null), 'help')
})

test('a healthy state never borrows the icon of a broken one, or the other way round', () => {
  // The pairing the table above cannot catch on its own: swap two icons and
  // each assertion still finds *an* icon. What must hold is that the three
  // kinds stay apart.
  const ok = classify({ ...ready, state: 'current' }).icon
  for (const state of ['build_failed', 'check_failed', 'reticulando_splines']) {
    assert.notEqual(classify({ ...ready, state }).icon, ok, `${state} no puede llevar el icono de un sistema al dia`)
  }
  assert.notEqual(classify(ready).icon, ok)
  assert.notEqual(classify(ready).icon, classify({ ...ready, state: 'build_failed' }).icon)
})

test('none of these eight paths leaves the button dead and mute', () => {
  // A dead button with no reason is the one outcome a user can neither act on
  // nor report.
  //
  // The list is written out, not derived, and the name of this test counts
  // rather than saying "every": a path added to buttonFor with an empty reason
  // would not be caught here unless it is also added below. An earlier version
  // of this comment claimed it would, which was measured false. Deriving the
  // real set means enumerating the return paths of a function from outside it,
  // and that costs more than this test is worth -- so the honest move is the
  // narrower promise, and the price of it is that the count is maintained by
  // hand. It went from six to eight when `engine_running` grew a branch of its
  // own outside the ready state.
  //
  // Both properties are asserted per case, and that is the point of the loop
  // over a filter: the first version collected the cases that were disabled
  // *and* mute and asserted the collection was empty, so a mutant that enabled
  // every button emptied the list and the test passed green over seven other
  // failures. A filter that finds nothing must not read as a pass.
  const apagados = [
    ['status ausente', null],
    ['schema desconocido', { schema: 99, state: 'ready' }],
    ['estado desconocido', { ...ready, state: 'reticulando_splines' }],
    ['sin lista de bloqueos', onDisk],
    ['bloqueo con detalle', { ...ready, blockers: [{ code: 'dirty_tree', detail: 'el arbol tiene cambios' }] }],
    ['bloqueo sin detalle', { ...ready, blockers: [{ code: 'dirty_tree' }] }],
    ['motor corriendo, fuera de ready', { ...ready, state: 'current', blockers: [enMarcha] }],
    ['motor corriendo y sin detalle', { ...ready, state: 'current', blockers: [{ code: 'engine_running' }] }],
  ]
  for (const [nombre, status] of apagados) {
    const b = buttonFor(status)
    assert.equal(b.enabled, false, `${nombre}: este camino tiene que apagar el boton`)
    assert.ok(b.reason && b.reason.trim().length > 0,
      `${nombre}: un boton apagado sin motivo no se puede ni accionar ni reportar`)
  }
})

test('the label tells the truth about which apply this is', () => {
  // The one label that must never drift: "Aplicar al arrancar" and "Aplicar"
  // are two different operations -- nh switch now against nh boot at the next
  // start -- and a reboot-recommended update degraded to the plain label reads
  // as an offer to switch onto a new kernel right now.
  const boot = buttonFor({ ...ready, reboot_recommended: true, reboot_reason: ['nvidia-open'] })
  assert.equal(boot.action, 'apply-boot')
  assert.match(boot.label, /arrancar/)
  const now = buttonFor(ready)
  assert.equal(now.action, 'apply')
  assert.equal(now.label, 'Aplicar')
  assert.doesNotMatch(now.label, /arrancar/)
  assert.notEqual(boot.label, now.label)
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

// ---------------------------------------------------------------------------
// `checkFor`, and the panel that reads it.
//
// The panel draws the check TWICE over: leading, in every state that is not
// `ready`, and beside "Aplicar" when it is. The first version of Popout.qml had
// the second one wired to `enabled: !applying` -- so the fix recorded above,
// that a check must not be offered while the engine holds its lock, survived
// everywhere except in the place a user actually presses. Pulling the rule into
// its own function is what put it back under test; these pin it there.
// ---------------------------------------------------------------------------

test('checkFor offers the check on every state the engine is not busy in', () => {
  for (const state of ['ready', 'current', 'build_failed', 'check_failed']) {
    const c = checkFor({ ...ready, state })
    assert.equal(c.enabled, true, `${state}: nada impide comprobar`)
    assert.equal(c.label, 'Comprobar ahora')
    assert.equal(c.reason, '')
  }
})

test('checkFor refuses only for engine_running, in the engine words', () => {
  const busy = checkFor({ ...ready, blockers: [enMarcha] })
  assert.equal(busy.enabled, false)
  assert.equal(busy.reason, enMarcha.detail)
  assert.equal(busy.label, 'Comprobar ahora', 'lo apagado es el boton, no su nombre')
  for (const code of ['dirty_tree', 'wrong_branch', 'pending_reboot']) {
    assert.equal(checkFor({ ...ready, blockers: [{ code, detail: 'da igual lo que diga' }] }).enabled, true,
      `${code} para un apply, no una comprobacion`)
  }
})

test('checkFor finds engine_running wherever it sits, not only first', () => {
  // Same ordering fact as buttonFor's: blockers.sh appends the two git facts
  // before it looks at the lock, so on a machine being worked on the lock is
  // the third entry. A reader that only inspects blockers[0] passes every
  // one-element case above and fails exactly here.
  const c = checkFor({ ...ready, blockers: [
    { code: 'dirty_tree', detail: 'el arbol tiene cambios sin commitear' },
    { code: 'wrong_branch', detail: 'la rama no es main' },
    enMarcha,
  ]})
  assert.equal(c.enabled, false)
  assert.equal(c.reason, enMarcha.detail)
})

test('checkFor does not offer a check over a status it could not read', () => {
  for (const bad of [null, undefined, { schema: 99, state: 'ready' }, { ...ready, state: 'reticulando_splines' }]) {
    const c = checkFor(bad)
    assert.equal(c.enabled, false, 'un estado ilegible no es una invitacion a actuar sobre el')
    assert.ok(c.reason.trim().length > 0, 'y sigue debiendo una explicacion')
  }
})

test('the leading button and the check are the same button in every non-ready state', () => {
  // The panel hides its second button when the two labels match, so that they
  // are never drawn side by side saying the same word. If buttonFor ever
  // renamed its non-ready label the panel would silently start showing two
  // identical buttons -- one live and one dark, in the engine_running case.
  const casos = [
    ['current limpio', { ...ready, state: 'current' }],
    ['current ocupado', { ...ready, state: 'current', blockers: [enMarcha] }],
    ['build_failed', { ...ready, state: 'build_failed' }],
    ['check_failed', { ...ready, state: 'check_failed' }],
    ['sin lista de bloqueos', { ...onDisk, state: 'current' }],
  ]
  for (const [nombre, status] of casos) {
    const b = buttonFor(status)
    const c = checkFor(status)
    assert.equal(b.label, c.label, `${nombre}: el boton que encabeza ES la comprobacion`)
    assert.equal(b.enabled, c.enabled, `${nombre}: y no puede estar vivo cuando ella no lo esta`)
    assert.equal(b.reason, c.reason, `${nombre}: ni dar otra razon que ella`)
  }
})

test('a dark check button never leaves the panel without its reason', () => {
  // The invariant Popout.qml leans on, and the reason it draws ONE explanation
  // line instead of one per button. That line shows `buttonFor(...).reason`,
  // and it is hidden when it would merely repeat the headline. So for every
  // status where the check is refused, its sentence has to be reachable in one
  // of those two places -- otherwise the user meets a dead button with nothing
  // next to it, which is the one outcome they can neither act on nor report.
  const universo = [
    ['nada publicado', null],
    ['schema ajeno', { schema: 99, state: 'ready' }],
    ['estado desconocido', { ...ready, state: 'reticulando_splines' }],
    ['ready y ocupado', { ...ready, blockers: [enMarcha] }],
    ['ready, sucio y ocupado', { ...ready, blockers: [
      { code: 'dirty_tree', detail: 'el arbol tiene cambios sin commitear' }, enMarcha] }],
    ['current y ocupado', { ...ready, state: 'current', blockers: [enMarcha] }],
    ['build_failed y ocupado', { ...ready, state: 'build_failed', blockers: [enMarcha] }],
    ['ocupado y sin detalle', { ...ready, state: 'current', blockers: [{ code: 'engine_running' }] }],
  ]
  let apagados = 0
  for (const [nombre, status] of universo) {
    const c = checkFor(status)
    assert.equal(c.enabled, false, `${nombre}: este caso existe para probar un boton apagado`)
    apagados++
    assert.ok(c.reason.trim().length > 0, `${nombre}: sin motivo no se puede ni reportar`)
    const enLaLinea = buttonFor(status).reason.includes(c.reason)
    const enElTitular = classify(status).summary === c.reason
    assert.ok(enLaLinea || enElTitular,
      `${nombre}: el motivo no aparece ni en la linea de explicacion ni en el titular`)
  }
  assert.equal(apagados, universo.length, 'un filtro que no encuentra nada no puede leerse como un aprobado')
})
