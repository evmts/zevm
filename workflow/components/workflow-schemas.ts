/**
 * Re-export ralph output schemas for TOON workflow import.
 * TOON imports these via `imports.schemas`.
 */

// @ts-ignore — super-ralph linked dependency
import { ralphOutputSchemas } from "super-ralph";

export const TicketSchedule = ralphOutputSchemas.ticket_schedule;
export const Discover = ralphOutputSchemas.discover;
export const Progress = ralphOutputSchemas.progress;
export const Research = ralphOutputSchemas.research;
export const Plan = ralphOutputSchemas.plan;
export const Implement = ralphOutputSchemas.implement;
export const TestResults = ralphOutputSchemas.test_results;
export const BuildVerify = ralphOutputSchemas.build_verify;
export const SpecReview = ralphOutputSchemas.spec_review;
export const CodeReview = ralphOutputSchemas.code_review;
export const CodeReviewCodex = ralphOutputSchemas.code_review_codex;
export const CodeReviewGemini = ralphOutputSchemas.code_review_gemini;
export const ReviewFix = ralphOutputSchemas.review_fix;
export const Report = ralphOutputSchemas.report;
export const IntegrationTest = ralphOutputSchemas.integration_test;
export const CategoryReview = ralphOutputSchemas.category_review;
export const Land = ralphOutputSchemas.land;
