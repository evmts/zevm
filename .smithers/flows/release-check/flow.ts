import { Flow } from "@smthrs/flow"
import { Node } from "@smthrs/plan"
import { CiJob } from "@smthrs/sandbox"
import { Schema } from "effect"

const releaseVerify = CiJob.make("release-verify", {
  steps: [
    { name: "verify-release", run: "node npm/zevm/scripts/verify-release.cjs" },
    { name: "checkout-native", run: "bash tools/checkout-native.sh" },
    { name: "qualification-covered", run: "zig build qualification-check -- --require-covered" },
    { name: "release-metadata", run: "zig build release-metadata -- --out-dir zig-out/release/tag --release-identifier \"$GITHUB_REF_NAME\"" }
  ]
})

export default Flow.make("release-check", {
  description: "Validate release version parity, qualification coverage, and canonical release metadata for tag pushes.",
  modelInvocable: false,
  payload: {
    run: Schema.String,
    repo: Schema.String,
    sha: Schema.String,
    ref: Schema.String,
    event: Schema.String
  },
  success: Schema.Struct({ releaseVerify: CiJob.Result }),
  body: (run) => Node.all({ releaseVerify: releaseVerify.call(run) })
})
