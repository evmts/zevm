declare module "smithers-orchestrator" {
  export const Workflow: any;
  export const Task: any;
  export const useCtx: any;
  export const smithers: any;
  export const outputs: any;
  export const db: any;
  export const createSmithers: any;
  export class GeminiAgent { constructor(...args: any[]); }
  export class AmpAgent { constructor(...args: any[]); }
  export class CodexAgent { constructor(...args: any[]); }
  export class KimiAgent { constructor(...args: any[]); }
}

declare module "smithers-orchestrator/jsx-runtime" {
  export const jsx: any;
  export const jsxs: any;
  export const Fragment: any;
}

declare module "super-ralph" {
  export const SuperRalph: any;
  export const ralphOutputSchemas: any;
}

declare module "../../docs/references/smithers/src/index" {
  export const createSmithers: any;
  export const CodexAgent: any;
  export const Loop: any;
  export const Sequence: any;
}

declare module "../../docs/references/smithers/src/jsx-runtime" {
  export const jsx: any;
  export const jsxs: any;
  export const Fragment: any;
}

declare module "../docs/references/smithers/src/index.ts" {
  export const mdxPlugin: any;
  export const runWorkflow: any;
}
