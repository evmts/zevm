import { Flow } from "@smthrs/flow"
import { Node } from "@smthrs/plan"
import { CiJob } from "@smthrs/sandbox"
import { Schema } from "effect"

const hygiene = CiJob.make("hygiene", {
  steps: [
    { name: "js-syntax", run: "for f in npm/zevm/src/*.js npm/zevm/scripts/*.cjs tools/*.mjs tools/*.js; do [ -e \"$f\" ] || continue; node --check \"$f\"; done" },
    { name: "docs-mirror", run: "node tools/docs_mirror.mjs" },
    { name: "llms-txt", run: "node tools/generate_llms_txt.mjs --check" },
    { name: "wiki-check", run: "node tools/wiki_sync.mjs --check" },
    { name: "release-parity", run: "node npm/zevm/scripts/verify-release.cjs" },
    { name: "audit-report-test", run: "node --test tools/audit_report.test.mjs" }
  ]
})

const zigFast = CiJob.make("zig-fast", {
  steps: [
    { name: "checkout-native", run: "bash tools/checkout-native.sh" },
    { name: "fetch-zig", run: "zig build --fetch" },
    { name: "preflight", run: "zig build dependency-preflight -- --zig-version 0.15.2" },
    { name: "verify-fast", run: "zig build verify-fast", timeoutSeconds: 600 },
    { name: "c-and-npm-smoke", run: "zig build c-smoke && zig build npm-smoke", timeoutSeconds: 600 }
  ]
})

const qualification = CiJob.make("qualification", {
  needs: ["hygiene", "zig-fast"],
  steps: [
    { name: "checkout-native", run: "bash tools/checkout-native.sh" },
    { name: "qualification-check", run: "zig build qualification-check" },
    { name: "release-binaries", run: "zig build release-binaries -Doptimize=ReleaseSafe", timeoutSeconds: 600 }
  ]
})

export default Flow.make("ci", {
  description: "Run ZEVM hygiene, Zig fast verification, C/N-API smokes, and release qualification gates.",
  modelInvocable: false,
  payload: {
    run: Schema.String,
    repo: Schema.String,
    sha: Schema.String,
    ref: Schema.String,
    event: Schema.String
  },
  success: Schema.Struct({
    hygiene: CiJob.Result,
    zigFast: CiJob.Result,
    qualification: CiJob.Result
  }),
  body: (run) =>
    Node.all({
      hygiene: hygiene.call(run),
      zigFast: zigFast.call(run),
      qualification: qualification.call(run)
    })
})
