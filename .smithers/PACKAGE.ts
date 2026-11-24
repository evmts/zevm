import { Smithers as S } from "@smthrs/targets"

// Factory projection: .smithers/FACTORY.ts and .smithers/flows/** render to
// the checked-in .smithers/factory.json and .smithers/home.json.
//   smthrs target //.smithers:factory-write --write   # regenerate
//   smthrs ci //.smithers:factory-check                # drift check (in ci)
export const Package = S.Package({
  targets: {
    "factory-write": S.FactoryProjection({ mode: "write" }),
    "factory-check": S.FactoryProjection({ mode: "check" }),
  },
})
