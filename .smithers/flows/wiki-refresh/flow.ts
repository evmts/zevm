import { Flow } from "@smthrs/flow"
import { Node } from "@smthrs/plan"
import { CiJob } from "@smthrs/sandbox"
import { Schema } from "effect"

const wikiCheck = CiJob.make("wiki-check", {
  steps: [
    { name: "wiki-integrity", run: "node tools/wiki_sync.mjs --check --out .smithers/reports/wiki-feed.json" }
  ]
})

export default Flow.make("wiki-refresh", {
  description: "Validate ZEVM Obsidian wiki links, source citations, and mythical history feed projection.",
  modelInvocable: false,
  payload: {
    run: Schema.String,
    repo: Schema.String,
    sha: Schema.String,
    ref: Schema.String,
    event: Schema.String
  },
  success: Schema.Struct({ wikiCheck: CiJob.Result }),
  body: (run) => Node.all({ wikiCheck: wikiCheck.call(run) })
})
