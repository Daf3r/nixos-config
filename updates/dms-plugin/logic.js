// Pure decisions for the bar plugin. No QML, no I/O — everything here is
// testable with `node --test`, which is the only part of a QML plugin that can
// be tested at all. Daemon.qml calls these and does nothing else with the data.

const SCHEMA = 2

// The rule the whole engine is built around: an incomplete or unreadable state
// must never render like a healthy one. Every early return here lands on
// 'unknown', never on 'ok'.
function classify(status) {
  if (!status || typeof status !== 'object') {
    return { state: 'unknown', icon: 'help', tone: 'unknown', summary: 'no se pudo leer el estado' }
  }
  if (status.schema !== SCHEMA) {
    return { state: 'unknown', icon: 'help', tone: 'unknown',
             summary: `status.json declara schema ${status.schema}, y este plugin entiende ${SCHEMA}` }
  }
  // The same reading upd.sh's `warn_count` already does, in its own words:
  // `(.warnings // []) | if type == "array" then length else 1 end`. A
  // `warnings` that is present but is not a list is a producer bug, and
  // counting it as one finding is what keeps a malformed status.json from
  // rendering as an all-clear on the panel. Two readers of one file that
  // disagree about what counts as clean is a bug waiting for a bad morning, so
  // this does not get to be cleverer than the shell -- including on `false`,
  // which jq's `//` swallows along with null, and which this got wrong for one
  // round while claiming to copy the rule.
  const w = status.warnings
  const absent = w === undefined || w === null || w === false
  const warned = Array.isArray(w) ? w.length > 0 : !absent
  switch (status.state) {
    case 'current':
      return { state: 'current', icon: 'check_circle', tone: warned ? 'warn' : 'ok',
               summary: 'todo al dia' }
    case 'ready':
      return { state: 'ready', icon: 'system_update_alt', tone: warned ? 'warn' : 'ready',
               summary: `${changeLines(status).length} cambios preparados` }
    case 'build_failed':
      return { state: 'build_failed', icon: 'error', tone: 'error',
               summary: 'la actualizacion preparada NO compila' }
    case 'check_failed':
      return { state: 'check_failed', icon: 'error', tone: 'error',
               summary: status.error || 'la comprobacion fallo' }
    default:
      return { state: 'unknown', icon: 'help', tone: 'unknown',
               summary: `estado desconocido: ${status.state}` }
  }
}

// What a blocker is allowed to say when it arrives with nothing in it.
// blockers.sh makes `detail` the whole message for a human -- literally what
// goes next to the disabled button -- so an empty one still owes the reader the
// admission and somewhere to go. The code is a poor substitute for a sentence,
// and still better than silence. Extracted so the two callers below cannot
// drift into two different answers for the same empty blocker.
function blockerDetail(b) {
  return b.detail || `bloqueo \`${b.code || 'sin codigo'}\` sin explicacion; mira \`upd status\``
}

// Whether asking the engine to look again is on offer, on its own.
//
// It has its own function because the panel draws the check TWICE over: as the
// leading button in every state that is not `ready`, and as a second button
// beside "Aplicar" when it is. Those two have to agree, and the first version of
// the panel made them disagree in exactly the way that matters -- the leading
// button honoured `engine_running` while the one next to Aplicar was
// unconditionally live, so the fix recorded below survived everywhere except in
// the place a user actually presses. Rules that live in the QML are rules no
// test can reach; this one lives here.
function checkFor(status) {
  const c = classify(status)
  if (c.tone === 'unknown') {
    // Nothing readable to check against, and the same answer buttonFor gives:
    // an unreadable state is not an invitation to act on it.
    return { label: 'Comprobar ahora', enabled: false, reason: c.summary }
  }
  // `engine_running` is the one blocker that speaks about a *check*, and until
  // it was pulled out here it was only ever consulted inside the `ready` branch
  // of buttonFor -- so the states that offer "Comprobar ahora" were precisely
  // the ones not asking. Measured: a `current` status with the engine holding
  // the lock drew a live button, and pressing it hands the user a run that waits
  // on a lock it cannot see. A button that offers to fail is worse than one that
  // says why it cannot.
  //
  // Only `engine_running` of the six. A dirty tree, a checked-out branch or a
  // pending reboot stop an *apply* and have nothing to say about a check, and
  // disabling on them would leave a dead button over a machine where checking
  // works fine.
  //
  // Nor does an absent list disable it, and that is a deliberate difference from
  // buttonFor's `ready` branch rather than an oversight. There the cost of
  // guessing wrong is an Aplicar the engine refuses; here it is a dead button
  // over a machine where the check would have succeeded, and between those two
  // the dead button is the worse answer.
  const running = Array.isArray(status.blockers)
    ? status.blockers.find(b => b.code === 'engine_running')
    : undefined
  if (running) {
    return { label: 'Comprobar ahora', enabled: false, reason: blockerDetail(running) }
  }
  return { label: 'Comprobar ahora', enabled: true, reason: '' }
}

// Interpret the two values returned by `systemctl show` when the daemon starts
// again. This is deliberately pure: the dangerous distinction is not QML, it
// is that `inactive + success` means "not running", never "it succeeded".
function reattachDecision(active, result, watching) {
  if (!active || !result)
    return { kind: 'unknown' }
  if (active === 'activating' || active === 'active')
    return { kind: 'running' }
  if (active === 'failed' || result === 'failed')
    return { kind: 'failed' }
  if (watching)
    return { kind: 'finished' }
  return { kind: 'absent' }
}

function buttonFor(status) {
  const c = classify(status)
  if (c.tone === 'unknown') {
    return { label: 'Sin estado', action: 'none', enabled: false, reason: c.summary }
  }
  if (status.state !== 'ready') {
    // The leading button in every non-ready state IS the check, so it says
    // whatever checkFor says. `action` is the only thing added: 'none' is what
    // stops the panel from firing a command behind a button it drew as dead.
    const check = checkFor(status)
    return { label: check.label, action: check.enabled ? 'check' : 'none',
             enabled: check.enabled, reason: check.reason }
  }
  // Missing is not empty, and the difference decides whether a button is live.
  // `blockers` exists only in `upd status --json`, which computes it on the
  // spot; /var/lib/nixos-upd/status.json has never carried the key and never
  // will, because two of the six conditions -- a dirty tree, a checked-out
  // branch -- are facts about the moment somebody looks. Measured on this
  // machine: the two documents are byte-identical apart from that one key.
  //
  // So an absent list means nobody asked, not that nothing is in the way, and
  // treating the two alike would put a live Aplicar button over a tree the
  // engine is going to refuse. Same failure as painting an unreadable state
  // green, one step further along.
  if (!Array.isArray(status.blockers)) {
    return { label: 'Aplicar', action: 'none', enabled: false,
             reason: 'este estado no trae la lista de bloqueos, asi que no se si algo impide aplicar; el panel tiene que sondear `upd status --json`, que la calcula en vivo, y no status.json, que nunca la lleva' }
  }
  const blockers = status.blockers
  if (blockers.length > 0) {
    // The engine's own wording, passed through untouched. Rewording it here
    // would mean maintaining two descriptions of the same refusal. Every one of
    // them, including codes this plugin has never heard of: blockers.sh states
    // outright that the vocabulary grew from four to six while it was being
    // written and can grow again.
    return { label: 'Aplicar', action: 'none', enabled: false,
             reason: blockers.map(blockerDetail).join('; ') }
  }
  if (!status.reboot_recommended) {
    return { label: 'Aplicar', action: 'apply', enabled: true, reason: '' }
  }
  // Why the button sends them to a reboot instead of a switch. The engine
  // always fills the list, so the empty branch is only ever reached by a
  // malformed status -- but "pide reinicio:" trailing into nothing reads as the
  // panel having broken, which is a worse answer than the shorter sentence.
  const why = Array.isArray(status.reboot_reason) ? status.reboot_reason : []
  return { label: 'Aplicar al arrancar', action: 'apply-boot', enabled: true,
           reason: why.length > 0 ? `pide reinicio: ${why.join(', ')}` : 'pide reinicio' }
}

function changeLines(status) {
  if (!status || !Array.isArray(status.changes)) return []
  return status.changes
    .filter(c => c.from !== c.to || c.hash_changed === true)
    .map(c => ({
      name: c.name,
      text: c.hash_changed === true && c.from === c.to
        ? `${c.from || '(sin version)'} (hash actualizado)`
        : `${c.from || '(nuevo)'} → ${c.to || '(fuera)'}`,
    }))
}

// Guarded because this file has two homes now, and only one of them has a
// `module`. Under `import "logic.js" as Logic` the QML engine exposes the
// top-level declarations of the script itself and defines nothing called
// `module`. Measured on Quickshell 0.3.0 / Qt 6.11 with the bare assignment:
// `@logic.js[..]: ReferenceError: module is not defined` on every load. The
// functions still answered, because the declarations above are hoisted before
// the throwing line -- so the failure is a warning in the log today and a
// silent dependency on evaluation order for as long as it is left there.
if (typeof module !== 'undefined')
  module.exports = { classify, buttonFor, checkFor, changeLines, reattachDecision, SCHEMA }
