import { describe, expect, test } from 'claude-code/testing'

import type { Feed, FeedBoard, FeedDecision } from '../types'
import {
  alerts,
  boardState,
  groupDecisions,
  linkHref,
  nextFirstSeen,
  toldDecisionIds,
} from '../hooks/model'

const BOARD_KEY = 'fb8ed9449f03a4d6'
const NOW_MS = Date.parse('2026-10-04T00:00:00Z')

function decision(over: Partial<FeedDecision>): FeedDecision {
  return {
    id: 'bul-3d-gfx-t1:gl-style-pick',
    task: 'bul-3d-gfx-t1',
    key: 'gl-style-pick',
    verb: 'needs-decision',
    at: NOW_MS / 1000 - 3600,
    project: 'buletin-ai',
    title: '3D WebGL stylized graphics for opening and closing - style board first',
    note: `Style board is up at http://192.168.50.3:4387/session/${BOARD_KEY} (dark). Pick one.`,
    urls: [`http://192.168.50.3:4387/session/${BOARD_KEY}`],
    ...over,
  }
}

function board(over: Partial<FeedBoard>): FeedBoard {
  return {
    key: BOARD_KEY,
    url: `http://192.168.50.3:4387/session/${BOARD_KEY}`,
    pending: 0,
    last_role: null,
    last_at: null,
    updated_at: '2026-10-03T12:00:00Z',
    listening: true,
    name: 'bul-3d-gfx',
    project: 'buletin-ai',
    task: 'bul-3d-gfx-t1',
    ...over,
  }
}

function feed(over: Partial<Feed>): Feed {
  return {
    generated: '2026-10-04T00:00:00Z',
    decisions: [],
    boards: [],
    holds: [],
    holds_other: 0,
    prs: [],
    underway: 0,
    inbox: 0,
    ...over,
  }
}

describe('board state', () => {
  test('feedback nobody receives is stranded', () => {
    expect(boardState(board({ pending: 2, listening: false }))).toBe('stranded')
  })
  test('delivered feedback with the listener gone is the worker busy', () => {
    expect(boardState(board({ last_role: 'user', listening: false }))).toBe('working')
  })
  test('a listening board waits on the captain', () => {
    expect(boardState(board({ last_role: 'agent' }))).toBe('ready')
  })
  test('a board nobody listens on with nothing pending is idle', () => {
    expect(boardState(board({ listening: false }))).toBe('idle')
  })
  test('a listening board whose task has no open decision is the worker busy', () => {
    expect(boardState(board({ last_role: 'agent', task: 't1', decision_open: false }))).toBe('working')
  })
  test('a listening board whose task has an open decision waits on the captain', () => {
    expect(boardState(board({ last_role: 'agent', task: 't1', decision_open: true }))).toBe('ready')
  })
  test('a silent board whose task has no open decision is idle', () => {
    expect(boardState(board({ listening: false, task: 't1', decision_open: false }))).toBe('idle')
  })
})

describe('decisions', () => {
  test('rounds of one task fold into one row linked through localhost', () => {
    const groups = groupDecisions([
      decision({}),
      decision({ id: 'bul-3d-gfx-t1:gl-style-pick-v2', key: 'gl-style-pick-v2', at: NOW_MS / 1000 }),
    ])
    expect(groups).toHaveLength(1)
    expect(groups[0]?.ids).toHaveLength(2)
    expect(groups[0]?.href).toBe(`http://localhost:4387/session/${BOARD_KEY}`)
  })

  test('a blocked task sorts above a newer question', () => {
    const groups = groupDecisions([
      decision({}),
      decision({ id: 'bul-daily-t1:default', task: 'bul-daily-t1', verb: 'blocked', at: 0, urls: [] }),
    ])
    expect(groups[0]?.task).toBe('bul-daily-t1')
  })

  test('only a reply written after the decision appeared tells the captain', () => {
    const open = [decision({})]
    const replies = [`old board http://192.168.50.3:4387/session/${BOARD_KEY}`, 'unrelated']
    expect(toldDecisionIds(open, replies, { [open[0]!.id]: 1 })).toEqual([])
    expect(toldDecisionIds(open, [...replies, `Board: ${BOARD_KEY}`], { [open[0]!.id]: 1 })).toEqual([open[0]!.id])
  })

  test('a board named as lavish-<key> in the note still matches the reply', () => {
    const open = [decision({ note: `board armed (lavish-${BOARD_KEY})`, urls: [] })]
    expect(toldDecisionIds(open, [`see http://x/session/${BOARD_KEY}`], {})).toEqual([open[0]!.id])
  })

  test('a shorter transcript is a clear and resets every first-seen count', () => {
    expect(nextFirstSeen({ a: 9, b: 4 }, ['a', 'b', 'c'], 2, false)).toEqual({ a: 0, b: 0, c: 0 })
    expect(nextFirstSeen({ a: 1 }, ['a', 'c'], 5, false)).toEqual({ a: 1, c: 5 })
  })
})

describe('links', () => {
  test('LAN http becomes localhost and https passes through', () => {
    expect(linkHref('http://192.168.50.3:4387/session/x')).toBe('http://localhost:4387/session/x')
    expect(linkHref('https://github.com/o/r/pull/6')).toBe('https://github.com/o/r/pull/6')
    expect(linkHref(null)).toBe(null)
  })
})

describe('alerts', () => {
  test('a new decision and stranded feedback each toast once', () => {
    const before = feed({})
    const after = feed({ decisions: [decision({})], boards: [board({ pending: 1, listening: false })] })
    const first = alerts(before, after, [], NOW_MS, 4)
    expect(first.toasts).toHaveLength(2)
    expect(alerts(after, after, first.alerted, NOW_MS, 4).toasts).toEqual([])
  })

  test('session start folds long-waiting boards into one toast', () => {
    const waiting = feed({
      boards: [board({ key: 'a'.repeat(16), name: 'a' }), board({ key: 'b'.repeat(16), name: 'b' })],
    })
    const raised = alerts(null, waiting, [], NOW_MS, 4)
    expect(raised.toasts).toEqual(['● 2 boards have waited on you for over 4h'])
  })
})

const FIXTURE = feed({
  decisions: [decision({})],
  boards: [board({ last_role: 'agent' }), board({ key: 'c'.repeat(16), name: 'apply', listening: false })],
  holds: [{ task: 'd20-care-t1', project: 'project-d20', title: 'care board', reason: 'paused', age_days: 1, pr: null }],
  workers: [
    { task: 'd20-anim-style-t1', project: 'project-d20', title: '2D/3D animation style board', state: 'working', since: NOW_MS / 1000 - 600 },
  ],
})

for (const surface of ['terminal', 'desktop'] as const) {
  test(`pane draws the fleet on ${surface}`, async ($, on) => {
    on('process.run', async () => ({
      value: {
        exitCode: 0,
        stdout: JSON.stringify(FIXTURE),
        stderr: '',
        isStdoutTruncated: false,
        isStderrTruncated: false,
      },
    }))
    // The harness keeps no pane list, so the test stands in for the engine's.
    const open = new Set<string>()
    on('ui.open', (_$, e) => {
      open.add(e.id)
      return { value: { isPlaced: true } }
    })
    on('ui.panes', () => ({
      value: [...open].map(id => ({ id, title: 'Bridge', isShown: true, isFocused: false, isPlaced: true })),
    }))
    await $.command.run({
      command: 'bridge',
      args: '',
      origin: { kind: 'composer' },
      presentation: { isFullscreen: true, columns: 160 },
    })

    const pane = await $.ui.mount({
      plugin: 'bridge',
      surface,
      component: 'Pane',
      requestId: 'bridge',
      props: { title: 'Bridge', isFocused: false, bodyColumns: 70, placement: 'dock', scroll: { offset: 0, bodyRows: 40 }, view: {} },
    })
    expect((await pane.find({ type: 'Box' }))?.props.backgroundColor).toBe('#000000')
    expect(await pane.find({ text: /3D WebGL stylized graphics/ })).toBeDefined()
    expect(await pane.find({ text: /not told/ })).toBeDefined()
    expect(await pane.find({ text: /your turn/ })).toBeDefined()
    expect(await pane.find({ text: /idle {6}/ })).toBeDefined()
    expect(await pane.find({ text: /1 without a board/ })).toBeDefined()
    expect(await pane.find({ text: /2D\/3D animation style board/ })).toBeDefined()
    expect(await pane.find({ key: `copy-${BOARD_KEY}` })).toBeDefined()
    const link = await pane.find({ type: 'Link', text: `http://192.168.50.3:4387/session/${BOARD_KEY}` })
    expect(link?.props.href).toBe(`http://localhost:4387/session/${BOARD_KEY}`)

    await pane.press({ key: 'told-bul-3d-gfx-t1' })
    expect(await pane.find({ key: 'told-bul-3d-gfx-t1' })).toBeUndefined()
    await pane.unmount()

  })
}

test('/bridge hides an open pane and shows it again', async ($, on) => {
  on('process.run', async () => ({
    value: { exitCode: 0, stdout: JSON.stringify(FIXTURE), stderr: '', isStdoutTruncated: false, isStderrTruncated: false },
  }))
  const seen: string[] = []
  // Nothing stands beneath the test's hooks, so they answer for the engine.
  on('ui.open', (_$, e) => {
    seen.push(`open ${e.id}`)
    return { value: { isPlaced: true } }
  })
  on('ui.close', (_$, e) => {
    seen.push(`close ${e.id}`)
    return { value: undefined }
  })
  // The harness keeps no pane list, so the test derives it from the opens and closes it saw.
  on('ui.panes', () => {
    const last = seen.filter(entry => entry.endsWith(' bridge')).at(-1)
    return {
      value: last?.startsWith('open')
        ? [{ id: 'bridge', title: 'Bridge', isShown: true, isFocused: false, isPlaced: true }]
        : [],
    }
  })
  const run = (args: string) =>
    $.command.run({ command: 'bridge', args, origin: { kind: 'composer' }, presentation: { isFullscreen: true, columns: 160 } })

  expect((await run('')).text).toBe('Bridge pane shown.')
  expect((await run('')).text).toBe('Bridge pane hidden. `/bridge` shows it again.')
  expect((await run('on')).text).toBe('Bridge pane shown.')
  expect(seen).toEqual(['open bridge', 'close bridge', 'open bridge'])
})
