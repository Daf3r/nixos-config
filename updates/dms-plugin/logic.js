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

function buttonFor(status) {
  const c = classify(status)
  if (c.tone === 'unknown') {
    return { label: 'Sin estado', action: 'none', enabled: false, reason: c.summary }
  }
  if (status.state !== 'ready') {
    return { label: 'Comprobar ahora', action: 'check', enabled: true, reason: '' }
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
    // would mean maintaining two descriptions of the same refusal.
    //
    // The fallback is not decoration. blockers.sh makes the detail the whole
    // message for a human -- literally what goes next to the disabled button --
    // so a blocker that arrives without one would leave a dead Aplicar and no
    // reason at all: the one outcome a user can neither act on nor report. The
    // code is a poor substitute for a sentence, and still better than silence.
    return { label: 'Aplicar', action: 'none', enabled: false,
             reason: blockers.map(b => b.detail
               || `bloqueo \`${b.code || 'sin codigo'}\` sin explicacion; mira \`upd status\``).join('; ') }
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
    .filter(c => c.from !== c.to)
    .map(c => ({
      name: c.name,
      text: `${c.from || '(nuevo)'} → ${c.to || '(fuera)'}`,
    }))
}

module.exports = { classify, buttonFor, changeLines, SCHEMA }
