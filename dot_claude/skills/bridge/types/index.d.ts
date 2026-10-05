export type FeedDecision = {
  id: string
  task: string
  key: string
  verb: string
  at: number
  project: string
  title: string
  note: string
  urls: string[]
}

export type FeedBoard = {
  key: string
  url: string
  pending: number
  last_role: 'user' | 'agent' | null
  last_at: string | null
  updated_at: string | null
  listening: boolean
  name: string
  project: string
  task: string | null
  decision_open?: boolean | null
}

export type FeedHold = {
  task: string
  project: string
  title: string
  reason: string
  age_days: number | null
  pr: string | null
}

export type FeedPr = {
  task: string
  project: string
  title: string
  url: string
  state: string
}

export type FeedWorker = {
  task: string
  project: string
  title: string
  state: string
  since: number | null
}

export type Feed = {
  generated: string | null
  decisions: FeedDecision[]
  boards: FeedBoard[]
  holds: FeedHold[]
  holds_other: number
  prs: FeedPr[]
  workers?: FeedWorker[]
  underway: number
  inbox: number
}

declare module 'claude-code' {
  interface PluginState {
    bridge: {
      feed: Feed | null
      error: string | null
      fetchedAt: number
      told: string[]
      marked: string[]
      firstSeen: Record<string, number>
      alerted: string[]
    }
  }
}
