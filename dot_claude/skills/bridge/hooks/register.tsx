import { atom, read, update } from 'claude-code'
import type { EngineInterface, Register, ResolveInput } from 'claude-code'

import type { Feed, FeedBoard } from '../types'
import {
  age,
  alerts,
  boardState,
  firstSentence,
  groupDecisions,
  isAging,
  isGroupTold,
  linkHref,
  nextFirstSeen,
  shortTitle,
  sortedBoards,
  toldDecisionIds,
  waitingSinceMs,
} from './model'
import type { BoardState, DecisionGroup } from './model'

const PANE = 'bridge'
const TITLE = 'Bridge'

const feedAtom = atom({ plugin: 'bridge', key: 'feed' } as const, null)
const errorAtom = atom({ plugin: 'bridge', key: 'error' } as const, null)
const fetchedAtAtom = atom({ plugin: 'bridge', key: 'fetchedAt' } as const, 0)
const toldAtom = atom({ plugin: 'bridge', key: 'told' } as const, [])
const markedAtom = atom({ plugin: 'bridge', key: 'marked' } as const, [])
const firstSeenAtom = atom({ plugin: 'bridge', key: 'firstSeen' } as const, {})
const alertedAtom = atom({ plugin: 'bridge', key: 'alerted' } as const, [])

const BOARD_LOOK: Record<BoardState, { glyph: string; word: string; color?: string }> = {
  stranded: { glyph: '✉', word: 'stranded', color: 'red' },
  ready: { glyph: '●', word: 'your turn', color: 'yellow' },
  delivering: { glyph: '↻', word: 'sending', color: 'cyan' },
  working: { glyph: '↻', word: 'working', color: 'cyan' },
  idle: { glyph: '◌', word: 'idle' },
}

// A worker without a board reports its own state, which uses the fleet words.
const WORKER_LOOK: Record<string, { glyph: string; word: string; color?: string }> = {
  working: { glyph: '↻', word: 'working', color: 'cyan' },
  paused: { glyph: '‖', word: 'waiting' },
  blocked: { glyph: '▲', word: 'blocked', color: 'red' },
  done: { glyph: '✓', word: 'done', color: 'green' },
  failed: { glyph: '▲', word: 'failed', color: 'red' },
}

const PROJECT_COLORS = ['magenta', 'cyan', 'green']

function projectColor(project: string): string {
  let hash = 0
  for (const char of project) {
    hash = (hash * 31 + char.charCodeAt(0)) >>> 0
  }

  return PROJECT_COLORS[hash % PROJECT_COLORS.length] ?? 'cyan'
}

function plural(count: number, noun: string): string {
  return `${count} ${noun}${count === 1 ? '' : 's'}`
}

function clock(iso: string | null): string {
  if (!iso) {
    return '--:--'
  }
  const date = new Date(iso)

  return `${String(date.getHours()).padStart(2, '0')}:${String(date.getMinutes()).padStart(2, '0')}`
}

// Set once per load from the manifest's userConfig; module variables, since
// the validator only follows $ into functions declared at the top of the file.
let fmHome = '/home/ariff/firstmate'
let refreshMs = 60_000
let waitHours = 4
let inFlight: Promise<void> | null = null

async function markTold($: EngineInterface, feed: Feed, isFirstLoad: boolean) {
  const assistantTexts = (await $.session.messages())
    .filter(message => message.role === 'assistant')
    .map(message => message.text)
  const ids = feed.decisions.map(decision => decision.id)
  const firstSeen = nextFirstSeen(await read($, firstSeenAtom), ids, assistantTexts.length, isFirstLoad)
  await update($, firstSeenAtom, () => firstSeen)
  await update($, toldAtom, () => toldDecisionIds(feed.decisions, assistantTexts, firstSeen))
  // A manual mark belongs to the decision it was pressed on and goes when it closes.
  await update($, markedAtom, marked => marked.filter(id => ids.includes(id)))
}

async function fetchFeed($: EngineInterface) {
  const ran = await $.process.run(['bash', `${$.plugin.root}/bin/bridge-feed.sh`, fmHome], {
    timeoutMs: 60_000,
  })
  if (ran.exitCode !== 0) {
    const reason = ran.stderr.trim().split('\n').at(-1) || `exit ${ran.exitCode}`
    throw new Error(`bridge-feed.sh ${fmHome} failed: ${reason}`)
  }
  const feed = JSON.parse(ran.stdout) as Feed
  const previous = await read($, feedAtom)
  const raised = alerts(previous, feed, await read($, alertedAtom), Date.now(), waitHours)
  await update($, alertedAtom, () => raised.alerted)
  raised.toasts.forEach(text => $.ui.toast(text, { timeoutMs: 8000 }))
  await update($, feedAtom, () => feed)
  await update($, errorAtom, () => null)
  await update($, fetchedAtAtom, () => Date.now())
  await markTold($, feed, previous === null)
}

function refresh($: EngineInterface): Promise<void> {
  inFlight ??= fetchFeed($)
    .catch(error => update($, errorAtom, () => String(error instanceof Error ? error.message : error)))
    .then(() => undefined)
    .finally(() => {
      inFlight = null
    })

  return inFlight
}

async function drawBridge($: EngineInterface, e: ResolveInput) {
  const { Box, Button, Link, Text } = $.ui.resolve(e)
  const feed = await read($, feedAtom)
  const error = await read($, errorAtom)
  const nowMs = Date.now()

  const header = (
    <Box flexDirection="row">
      <Box flexGrow={1}>
        <Text bold>◈ Bridge</Text>
      </Box>
      <Text dimColor>{`updated ${clock(feed?.generated ?? null)} `}</Text>
      <Button key="refresh" plain label="↻" onPress={() => refresh($)} />
    </Box>
  )
  if (!feed) {
    return (
      <Box flexDirection="column">
        {header}
        {error ? <Text color="red">▲ {error}</Text> : <Text dimColor>Reading the fleet…</Text>}
      </Box>
    )
  }

  const told = await read($, toldAtom)
  const marked = await read($, markedAtom)
  const groups = groupDecisions(feed.decisions)
  const boardsWithDecision = new Set(groups.flatMap(group => group.tokens.filter(token => /^[0-9a-f]{16}$/.test(token))))

  const section = (glyph: string, label: string, count: string, color?: string) => (
    <Box flexDirection="row" marginTop={1}>
      <Text bold color={color}>{`${glyph} ${label}`}</Text>
      <Text dimColor>{`  ${count}`}</Text>
    </Box>
  )

  // The label is the real address, which also opens from a phone on the LAN;
  // the link itself goes through localhost, the one http host Link accepts.
  const urlLine = (id: string, url: string | null, href: string | null) =>
    url &&
    href && (
      <Box key={`u-${id}`} flexDirection="row" paddingLeft={2}>
        <Box flexShrink={1}>
          <Link href={href} label={url} />
        </Box>
        <Text> </Text>
        <Button
          key={`copy-${id}`}
          plain
          dimColor
          label="⧉"
          onPress={press => $.ui.copy({ text: url, surface: press.surface })}
        />
      </Box>
    )

  const decisionRow = (group: DecisionGroup) => {
    const isTold = isGroupTold(group, told, marked)
    const aging = isAging(group, nowMs)
    const answer = `For the ${group.project} ${shortTitle(group.title)} decision: `
    const badge = group.isBlocked ? '▲ blocked' : !isTold ? 'not told' : aging ? 'aging' : ''
    const badgeColor = group.isBlocked ? 'red' : !isTold ? 'yellow' : undefined
    const questions = group.ids.length > 1 ? ` · ${group.ids.length} questions` : ''

    return (
      <Box key={`d-${group.task}`} flexDirection="column">
        <Box flexDirection="row">
          <Text color={isTold ? undefined : 'yellow'} dimColor={isTold}>{isTold ? '○ ' : '● '}</Text>
          <Text color={projectColor(group.project)}>{`${group.project} `}</Text>
          <Box flexGrow={1} flexShrink={1}>
            <Text wrap="truncate-end" bold={!isTold}>{shortTitle(group.title)}</Text>
          </Box>
          <Text dimColor>{` ${age(group.newestAt * 1000, nowMs)} `}</Text>
          {!isTold && (
            <Button
              key={`told-${group.task}`}
              plain
              dimColor
              label="✓"
              onPress={() => update($, markedAtom, list => [...new Set([...list, ...group.ids])])}
            />
          )}
          {!isTold && <Text> </Text>}
          <Button
            key={`answer-${group.task}`}
            plain
            dimColor
            label="↵"
            onPress={() => $.prompt.fill({ text: answer, mode: 'insert' })}
          />
        </Box>
        <Box flexDirection="row" paddingLeft={2}>
          {/* The badge never shrinks: a long note squeezing it wraps the dot onto its own row. */}
          {badge !== '' && (
            <Box flexShrink={0}>
              <Text color={badgeColor} dimColor={!badgeColor}>{`${badge}${questions} ·`}</Text>
            </Box>
          )}
          {/* A trailing space inside the badge is trimmed when the note wraps, so the gap is layout. */}
          <Box flexGrow={1} flexShrink={1} marginLeft={badge !== '' ? 1 : 0}>
            <Text dimColor wrap="truncate-end">{firstSentence(group.note)}</Text>
          </Box>
        </Box>
        {urlLine(group.task, group.url, group.href)}
      </Box>
    )
  }

  const boardRow = (board: FeedBoard) => {
    const state = boardState(board)
    const look = BOARD_LOOK[state]
    const href = linkHref(board.url)

    return (
      <Box key={`b-${board.key}`} flexDirection="column">
        <Box flexDirection="row">
          <Text color={look.color} dimColor={!look.color}>{`${look.glyph} ${look.word.padEnd(10)}`}</Text>
          <Box flexGrow={1} flexShrink={1}>
            <Text wrap="truncate-end">
              {board.name}
              {boardsWithDecision.has(board.key) && <Text color="yellow">{' ◆'}</Text>}
              <Text dimColor>{`  ${board.project}`}</Text>
            </Text>
          </Box>
          <Text dimColor>{` ${age(waitingSinceMs(board), nowMs)}`}</Text>
        </Box>
        {urlLine(board.key, board.url, href)}
      </Box>
    )
  }

  const boards = sortedBoards(feed.boards)
  const activeBoards = boards.filter(board => boardState(board) !== 'idle')
  const idleBoards = boards.filter(board => boardState(board) === 'idle')
  const untold = groups.filter(group => !isGroupTold(group, told, marked)).length
  const parkedShown = feed.holds.slice(0, 5)
  const workers = feed.workers ?? []

  return (
    <Box flexDirection="column">
      {header}
      {error && <Text color="red" wrap="truncate-end">▲ last refresh failed · {error}</Text>}

      {section('◆', 'Decisions', groups.length === 0 ? 'none' : `${groups.length} · ${untold} not told`, 'yellow')}
      {groups.length === 0 && <Text color="green">✓ Nothing waiting on your word.</Text>}
      {groups.map(decisionRow)}

      {section('▣', 'Boards', `${activeBoards.length} active · ${idleBoards.length} idle`, 'cyan')}
      {activeBoards.map(boardRow)}
      {idleBoards.map(boardRow)}

      {workers.length > 0 && section('↻', 'Workers', `${workers.length} without a board`, 'cyan')}
      {workers.map(worker => {
        const look = WORKER_LOOK[worker.state] ?? { glyph: '◌', word: worker.state }

        return (
          <Box key={`w-${worker.task}`} flexDirection="row">
            <Text color={look.color} dimColor={!look.color}>{`${look.glyph} ${look.word.padEnd(10)}`}</Text>
            <Text color={projectColor(worker.project)}>{`${worker.project} `}</Text>
            <Box flexGrow={1} flexShrink={1}>
              <Text wrap="truncate-end">{shortTitle(worker.title)}</Text>
            </Box>
            <Text dimColor>{worker.since ? ` ${age(worker.since * 1000, nowMs)}` : ''}</Text>
          </Box>
        )
      })}

      {feed.prs.length > 0 && section('⇡', 'PRs ready', `${feed.prs.length}`, 'green')}
      {feed.prs.map(pr => (
        <Box key={`p-${pr.task}`} flexDirection="row">
          <Text color={projectColor(pr.project)}>{`${pr.project} `}</Text>
          <Box flexGrow={1} flexShrink={1}>
            <Text wrap="truncate-end">{shortTitle(pr.title)}</Text>
          </Box>
          <Text dimColor>{` ${pr.state} `}</Text>
          {linkHref(pr.url) && <Link href={linkHref(pr.url) ?? pr.url} label="↗" />}
        </Box>
      ))}

      {feed.holds.length > 0 &&
        section('‖', 'Parked by you', feed.holds_other > 0 ? `${feed.holds.length} · ${feed.holds_other} dated` : `${feed.holds.length}`)}
      {parkedShown.map(hold => (
        <Box key={`h-${hold.task}`} flexDirection="row">
          <Text dimColor>{'‖ '}</Text>
          <Text color={projectColor(hold.project)} dimColor>{`${hold.project} `}</Text>
          <Box flexGrow={1} flexShrink={1}>
            <Text dimColor wrap="truncate-end">{shortTitle(hold.title)}</Text>
          </Box>
          <Text dimColor>{hold.age_days !== null ? ` ${hold.age_days}d ` : ' '}</Text>
          {linkHref(hold.pr) && <Link href={linkHref(hold.pr) ?? ''} label="↗" />}
        </Box>
      ))}
      {feed.holds.length > parkedShown.length && (
        <Text dimColor>{`  +${feed.holds.length - parkedShown.length} more`}</Text>
      )}

      <Box flexDirection="row" marginTop={1}>
        <Text dimColor wrap="truncate-end">
          {`✎ ${plural(feed.inbox, 'note')} · ↻ ${feed.underway} under way`}
        </Text>
      </Box>
      <Text dimColor wrap="truncate-end">click a URL to open · ⧉ copy · ✓ mark told · ↵ answer in prompt</Text>
    </Box>
  )
}

function isUnder(dir: string, root: string): boolean {
  const base = root.replace(/\/+$/, '')

  return dir === base || dir.startsWith(`${base}/`)
}

async function isPaneUp($: EngineInterface): Promise<boolean> {
  return (await $.ui.panes()).some(pane => pane.id === PANE)
}

function openPane($: EngineInterface) {
  void refresh($)

  return $.ui.open({ id: PANE, title: TITLE })
}

export const register: Register = (on, options) => {
  fmHome = String(options.fmHome ?? fmHome)
  refreshMs = Math.max(15, Number(options.refreshSeconds ?? 60)) * 1000
  waitHours = Math.max(1, Number(options.boardWaitHours ?? 4))

  on('session.start', async ($, e, next) => {
    await $.command.register({
      name: 'bridge',
      description: 'Show or hide the Bridge side pane',
    })
    // Only a session working in the firstmate home needs the fleet at hand;
    // every other session opens it on demand.
    if (isUnder(await $.session.root(), fmHome)) {
      void openPane($)
    }
    // The feed runs a process, so a session with the pane hidden skips it.
    $.clock.every(refreshMs, async () => {
      if (await isPaneUp($)) {
        void refresh($)
      }
    })

    return next(e)
  })

  on('command.run', { command: 'bridge' }, async ($, e) => {
    const wanted = e.args.trim()
    const show = wanted === 'on' ? true : wanted === 'off' ? false : !(await isPaneUp($))
    if (!show) {
      await $.ui.close({ id: PANE })

      return { text: 'Bridge pane hidden. `/bridge` shows it again.' }
    }
    await openPane($)

    return { text: 'Bridge pane shown.' }
  })

  on('turn.complete', async ($, e, next) => {
    const ran = await next(e)
    if (!(await isPaneUp($))) {
      return ran
    }
    const feed = await read($, feedAtom)
    if (feed) {
      await markTold($, feed, false)
    }
    // A turn often answers or opens a decision, so the pane catches up at once
    // instead of waiting out the timer.
    if (Date.now() - (await read($, fetchedAtAtom)) > 20_000) {
      void refresh($)
    }

    return ran
  })

  // Claude Code paints a docked pane grey and no tree can make it see-through,
  // so the pane is filled black edge to edge instead.
  on('ui.render', { component: 'Pane', requestId: PANE }, async ($, e) => {
    const { Box } = $.ui.resolve(e)

    return (
      <Box
        flexDirection="column"
        backgroundColor="#000000"
        width={e.props.bodyColumns}
        minHeight={e.props.scroll.bodyRows}
      >
        {await drawBridge($, e)}
      </Box>
    )
  })
}
