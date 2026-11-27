import { Flow } from "@smthrs/flow"
import { Node } from "@smthrs/plan"
import { CiJob } from "@smthrs/sandbox"
import { Schema } from "effect"

const uphill = CiJob.make("uphill", {
  steps: [
    { name: "uphill", run: "uphill --compact" },
    { name: "lighthouse-audit-report", run: "node tools/audit_report.mjs --input .uphill/report.json --out .uphill/audit-report.html --feed-out .uphill/factory-feed.json --md-out .uphill/audit-comment.md" }
  ]
})

export default Flow.make("uphill", {
  description: "Score ZEVM Uphill metrics and generate the Lighthouse-style backpressure audit report.",
  modelInvocable: false,
  payload: {
    run: Schema.String,
    repo: Schema.String,
    sha: Schema.String,
    ref: Schema.String,
    event: Schema.String
  },
  success: Schema.Struct({ uphill: CiJob.Result }),
  body: (run) => Node.all({ uphill: uphill.call(run) })
})
