const test = require('node:test')
const assert = require('node:assert')
const Model = require('../Model.js')

// --- parseCache: bounded model -------------------------------------------

function cacheWithTasks(n, title) {
  return JSON.stringify({
    syncedAt: 1755000000,
    authRequired: false,
    account: 'me@example.com',
    listId: 'abc',
    listName: 'Tasks',
    tasks: Array.from({ length: n }, (_, i) => ({
      id: 't' + i,
      title: (title || 'Task') + ' ' + i,
      completed: false,
      due: 0,
      remind: 0,
      isReminderOn: false,
      importance: 'normal',
      recurType: '',
      recurInterval: 1,
      recurDays: ''
    }))
  })
}

test('parseCache returns the empty shape on junk', () => {
  for (const raw of ['', 'not json', 'null', '[1,2]', '{"tasks": "nope"}']) {
    const c = Model.parseCache(raw)
    assert.deepEqual(c, {
      syncedAt: 0,
      authRequired: false,
      account: '',
      listId: '',
      listName: '',
      tasks: []
    })
  }
})

test('parseCache keeps a well-formed cache intact', () => {
  const c = Model.parseCache(cacheWithTasks(3))
  assert.equal(c.syncedAt, 1755000000)
  assert.equal(c.account, 'me@example.com')
  assert.equal(c.tasks.length, 3)
  assert.equal(c.tasks[1].title, 'Task 1')
})

test('parseCache caps the task array', () => {
  // The CLI writes at most MAX_TASKS_FETCH (250); a tampered file offering
  // far more must not balloon the model.
  const c = Model.parseCache(cacheWithTasks(1500))
  assert.equal(c.tasks.length, 1000)
})

test('parseCache truncates overlong titles and drops non-object rows', () => {
  const raw = JSON.stringify({
    tasks: [
      null,
      42,
      { id: 'a', title: 'x'.repeat(500) },
      { id: 'b' }
    ]
  })
  const c = Model.parseCache(raw)
  assert.equal(c.tasks.length, 2)
  assert.ok(c.tasks[0].title.length <= 200)
  assert.equal(c.tasks[1].title, '')
})

test('parseCache truncates account and list name text', () => {
  const raw = JSON.stringify({
    account: 'a'.repeat(400),
    listName: 'l'.repeat(400),
    listId: 'i'.repeat(400),
    tasks: []
  })
  const c = Model.parseCache(raw)
  assert.ok(c.account.length <= 200)
  assert.ok(c.listName.length <= 200)
  assert.equal(c.listId, 'i'.repeat(400)) // opaque id, never rendered
})

// --- parseNotified / pruneNotified ---------------------------------------

test('parseNotified accepts only objects', () => {
  assert.deepEqual(Model.parseNotified('{}'), {})
  assert.deepEqual(Model.parseNotified('{"t:5": 1755000000}'), { 't:5': 1755000000 })
  assert.deepEqual(Model.parseNotified('[1]'), {})
  assert.deepEqual(Model.parseNotified('garbage'), {})
  assert.deepEqual(Model.parseNotified(''), {})
})

test('pruneNotified keeps fresh entries and drops stale ones', () => {
  const now = 1_800_000_000
  const keep = 14 * 24 * 3600
  const pruned = Model.pruneNotified({
    fresh: now - keep + 60,     // inside the window
    edge: now - keep - 1,       // one second past it
    ancient: 1000,
    badstring: 'not-a-number'
  }, now)
  assert.deepEqual(pruned, { fresh: now - keep + 60 })
})

test('pruneNotified survives a null-ish map', () => {
  assert.deepEqual(Model.pruneNotified(null, Date.now() / 1000), {})
})

// --- parsePomoState ------------------------------------------------------

test('parsePomoState reads the daily tally', () => {
  const s = Model.parsePomoState(JSON.stringify({ dateKey: '2026-08-23', blocks: 3, minutes: 75 }))
  assert.deepEqual(s, { dateKey: '2026-08-23', blocks: 3, minutes: 75 })
})

test('parsePomoState falls back to the empty day on junk or partial data', () => {
  assert.deepEqual(Model.parsePomoState(''), { dateKey: '', blocks: 0, minutes: 0 })
  assert.deepEqual(Model.parsePomoState('nope'), { dateKey: '', blocks: 0, minutes: 0 })
  assert.deepEqual(Model.parsePomoState('{"blocks": "two"}'), { dateKey: '', blocks: 0, minutes: 0 })
})

// --- safeTodoWebUrl ------------------------------------------------------
//
// The web-app URL is a hard-coded constant; safeTodoWebUrl is a no-op defence
// in depth. If a future refactor ever templated the URL, this allowlist must
// fail closed (return "") rather than open a redirected host.

test('TODO_WEB_URL is the expected hard-coded constant', () => {
  assert.equal(Model.TODO_WEB_URL, 'https://to-do.live.com/tasks/today')
})

test('safeTodoWebUrl accepts the hard-coded URL', () => {
  assert.equal(
    Model.safeTodoWebUrl('https://to-do.live.com/tasks/today'),
    'https://to-do.live.com/tasks/today'
  )
})

test('safeTodoWebUrl rejects everything else (fail-closed)', () => {
  for (const bad of [
    '',
    null,
    undefined,
    'http://to-do.live.com/tasks/today',         // http not https
    'https://to-do.live.com/tasks/today/',       // trailing slash
    'https://to-do.live.com/tasks/today?evil=1', // smuggled query
    'https://to-do.office.com/tasks/today',      // wrong host
    'https://to-do.live.com.evil.example/tasks/today',
    'https://evil.example/tasks/today',
    'javascript:alert(1)',
    'file:///etc/passwd',
  ]) {
    assert.equal(Model.safeTodoWebUrl(bad), '', `should reject: ${bad}`)
  }
})
