import { Flow } from "@smthrs/flow"
import { Node } from "@smthrs/plan"
import { CiJob } from "@smthrs/sandbox"
import { Schema } from "effect"

const docsBuild = CiJob.make("docs-build", {
  steps: [
    { name: "docs-mirror", run: "node tools/docs_mirror.mjs" },
    { name: "llms-txt", run: "node tools/generate_llms_txt.mjs --write" },
    { name: "astro-build", run: "npm --prefix docs ci && npm --prefix docs run build", timeoutSeconds: 600 }
  ]
})

export default Flow.make("docs-publish", {
  description: "Verify docs mirror parity, regenerate llms.txt, and build the ZEVM Starlight docs bundle.",
  modelInvocable: false,
  payload: {
    run: Schema.String,
    repo: Schema.String,
    sha: Schema.String,
    ref: Schema.String,
    event: Schema.String
  },
  success: Schema.Struct({ docsBuild: CiJob.Result }),
  body: (run) => Node.all({ docsBuild: docsBuild.call(run) })
})
