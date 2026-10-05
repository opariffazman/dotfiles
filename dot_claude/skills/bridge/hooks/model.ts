import type { Feed, FeedBoard, FeedDecision } from '../types'

export type BoardState = 'stranded' | 'delivering' | 'working' | 'ready' | 'idle'

export type DecisionGroup = {
  task: string
  project: string
  title: string
  ids: string[]
  isBlocked: boolean
  newestAt: number
  note: string
  url: string | null
  href: string | null
  tokens: string[]
}

const HOUR_MS = 3_600_000
const DAY_MS = 24 * HOUR_MS
const AGING_MS = 2 * DAY_MS

// A Lavish board key is 16 hex characters. Captain-facing replies carry the
// board URL, and some decision notes name the board as `lavish-<key>` instead,
// so the key alone matches both.
const BOARD_KEY = /(?:\/session\/|lavish-)([0-9a-f]{16})\b/g

export function boardKeys(text: string): string[] {
  return [...text.matchAll(BOARD_KEY)].flatMap(match => (match[1] ? [match[1]] : []))
}

export function boardState(board: FeedBoard): BoardState {
  if (board.pending > 0) {
    return board.listening ? 'delivering' : 'stranded'
  }
  // Lavish drops the listener while the worker digests delivered feedback, so
  // a captain message with no listener is the worker busy, not the board dead.
  if (board.last_role === 'user' && !board.listening) {
    return 'working'
  }
  // The listener stays armed while the worker makes the next round, so a
  // known task with no open decision is still the worker's turn, not the captain's.
  if (board.task && board.decision_open === false) {
    return board.listening ? 'working' : 'idle'
  }

  return board.listening ? 'ready' : 'idle'
}

export function waitingSinceMs(board: FeedBoard): number {
  const stamp = board.last_at ?? board.updated_at

  return stamp ? Date.parse(stamp) : 0
}

const BOARD_ORDER: BoardState[] = ['stranded', 'ready', 'delivering', 'working', 'idle']

export function sortedBoards(boards: FeedBoard[]): FeedBoard[] {
  return [...boards].sort(
    (a, b) =>
      BOARD_ORDER.indexOf(boardState(a)) - BOARD_ORDER.indexOf(boardState(b)) ||
      waitingSinceMs(a) - waitingSinceMs(b),
  )
}

// Link refuses any http URL other than localhost, and the boards are served on
// a LAN address that this machine also reaches as localhost.
export function linkHref(url: string | null | undefined): string | null {
  if (!url) {
    return null
  }
  if (url.startsWith('https://')) {
    return url
  }
  const local = url.replace(/^http:\/\/[^/:]+(:\d+)?/, 'http://localhost$1')

  return local.startsWith('http://localhost') ? local : null
}

function preferredUrl(urls: string[]): string | null {
  return urls.find(url => boardKeys(url).length > 0) ?? urls.find(url => url.includes('/pull/')) ?? urls[0] ?? null
}

// One task can hold several open questions (a superseded round stays open
// until answered), and the captain answers them together on one board.
export function groupDecisions(decisions: FeedDecision[]): DecisionGroup[] {
  const groups = new Map<string, DecisionGroup>()
  for (const decision of decisions) {
    const group = groups.get(decision.task) ?? {
      task: decision.task,
      project: decision.project,
      title: decision.title,
      ids: [],
      isBlocked: false,
      newestAt: 0,
      note: '',
      url: null,
      href: null,
      tokens: [],
    }
    group.ids.push(decision.id)
    group.isBlocked ||= decision.verb === 'blocked'
    if (decision.at >= group.newestAt) {
      group.newestAt = decision.at
      group.note = decision.note
    }
    const tokens = [...decision.urls, ...boardKeys(decision.note), ...decision.urls.flatMap(boardKeys)]
    group.tokens = [...new Set([...group.tokens, ...tokens])]
    groups.set(decision.task, group)
  }
  for (const group of groups.values()) {
    group.url = preferredUrl(group.tokens.filter(token => token.includes('://')))
    group.href = linkHref(group.url)
  }

  return [...groups.values()].sort(
    (a, b) => Number(b.isBlocked) - Number(a.isBlocked) || b.newestAt - a.newestAt,
  )
}

// firstSeen records how many assistant replies existed when a decision first
// appeared, so only a reply written after it counts as telling the captain.
// A shorter transcript than any recorded count means a /clear: every open
// decision is then new to the conversation the captain now sees.
export function nextFirstSeen(
  previous: Record<string, number>,
  decisionIds: string[],
  assistantCount: number,
  isFirstLoad: boolean,
): Record<string, number> {
  const isCleared = Object.values(previous).some(count => count > assistantCount)
  const next: Record<string, number> = {}
  for (const id of decisionIds) {
    const known = isCleared ? undefined : previous[id]
    next[id] = known ?? (isFirstLoad || isCleared ? 0 : assistantCount)
  }

  return next
}

export function toldDecisionIds(
  decisions: FeedDecision[],
  assistantTexts: string[],
  firstSeen: Record<string, number>,
): string[] {
  return decisions
    .filter(decision => {
      const tokens = [...decision.urls, ...boardKeys(decision.note), ...decision.urls.flatMap(boardKeys)]
      if (tokens.length === 0) {
        return false
      }
      const since = firstSeen[decision.id] ?? 0

      return assistantTexts.slice(since).some(text => tokens.some(token => text.includes(token)))
    })
    .map(decision => decision.id)
}

export function isGroupTold(group: DecisionGroup, told: string[], marked: string[]): boolean {
  return group.ids.every(id => told.includes(id) || marked.includes(id))
}

export function isAging(group: DecisionGroup, nowMs: number): boolean {
  return group.newestAt > 0 && nowMs - group.newestAt * 1000 > AGING_MS
}

export function shortTitle(title: string): string {
  const head = title.split(/ - |, | \(|: /)[0] ?? title

  return head.length > 60 ? `${head.slice(0, 59)}…` : head
}

export function firstSentence(note: string): string {
  const sentence = note.match(/^.+?[.!?](?=\s|$)/)?.[0] ?? note

  return sentence.replace(/https?:\/\/\S+/g, '').replace(/\s+/g, ' ').trim()
}

export function age(fromMs: number, nowMs: number): string {
  if (fromMs <= 0) {
    return ''
  }
  const elapsed = Math.max(0, nowMs - fromMs)
  if (elapsed < 60_000) {
    return 'now'
  }
  if (elapsed < HOUR_MS) {
    return `${Math.floor(elapsed / 60_000)}m`
  }
  if (elapsed < DAY_MS) {
    return `${Math.floor(elapsed / HOUR_MS)}h`
  }

  return `${Math.floor(elapsed / DAY_MS)}d`
}

export type Alerts = { toasts: string[]; alerted: string[] }

export function alerts(
  previous: Feed | null,
  feed: Feed,
  alerted: string[],
  nowMs: number,
  waitHours: number,
): Alerts {
  const toasts: string[] = []
  const seen = new Set(alerted)
  const raise = (key: string, text: string) => {
    if (!seen.has(key)) {
      seen.add(key)
      toasts.push(text)
    }
  }

  if (previous) {
    const known = new Set(previous.decisions.map(decision => decision.id))
    for (const group of groupDecisions(feed.decisions.filter(decision => !known.has(decision.id)))) {
      raise(`decision:${group.ids.join(',')}`, `◆ New decision · ${group.project} · ${shortTitle(group.title)}`)
    }
  }
  const waits: { key: string; text: string }[] = []
  for (const board of feed.boards) {
    const state = boardState(board)
    if (state === 'stranded') {
      raise(
        `stranded:${board.key}:${board.pending}`,
        `✉ Feedback on ${board.name} is waiting and no worker is listening`,
      )
    }
    const since = waitingSinceMs(board)
    const key = `wait:${board.key}:${since}`
    if (state === 'ready' && since > 0 && nowMs - since > waitHours * HOUR_MS && !seen.has(key)) {
      waits.push({ key, text: `● ${board.name} has waited on you for ${age(since, nowMs)}` })
    }
  }
  // At session start every long-waiting board crosses the threshold at once,
  // and one toast per board would bury the prompt.
  if (!previous && waits.length > 1) {
    waits.forEach(wait => seen.add(wait.key))
    toasts.push(`● ${waits.length} boards have waited on you for over ${waitHours}h`)
  } else {
    waits.forEach(wait => raise(wait.key, wait.text))
  }

  return { toasts, alerted: [...seen] }
}
