# Lab 1: Navigating organizational intelligence

[Lab directory](./README.md) | [Next: Intelligent investigation](./lab-02-intelligent-investigation.md)

## Scenario and objectives

You are Serena Ribeiro, Caldova's Market Research Analyst. A proposal to accelerate the ALLER launch has created questions about readiness. Use Microsoft 365 Copilot Chat to explore what the organization already knows across meetings, email, Teams discussions, and documents.

By the end, you will be able to identify decisions and conflicting signals, trace claims to their sources, and explain how user permissions affect the answer.

**Estimated time:** 15-20 minutes.

## Prerequisites

1. Complete the [shared setup](./README.md#before-you-begin) with Microsoft 365 content provisioned.
2. Use Serena's account or its mapped replacement, with Microsoft 365 Copilot access to organizational work data.
3. Confirm access to **Market Research Team**, its **Launch Readiness** channel, and the site's documents.

You do not need Dynamics 365 for this lab.

## Exercise 1: Ask Copilot Chat

1. Open [Microsoft 365 Copilot Chat](https://copilot.cloud.microsoft/chat) and sign in with your assigned Serena identity.
2. Start a new conversation with Work IQ enabled, which should be the default behavior.
3. Submit this prompt:

   ```text
   I need to understand everything the organisation already knows — decisions taken in recent Teams meetings, related email threads with the regulatory and commercial teams, and formulation and market-access to prepare a readiness brief ahead of an accelerated next-generation product launch for the new ALLER product. Always provide a final evaluation as: Green, Amber, or Red.
   ```

4. Wait for the response and review its supporting sources. No custom agent or additional prompt is required for this exercise.

5. Verify that the overall result of the assessment should be **AMBER**.

## Exercise 2: Review the readiness brief

1. Review which launch decisions, readiness concerns, and dependencies Copilot found.
2. Open at least three citations, covering different evidence types where available. Relevant sources in the shipped data include:
   - Product Launch Readiness Assessment and Market Access Strategy
   - Launch Readiness Review and Executive Launch Checkpoint transcript documents
   - Launch War Room channel discussion
   - The email thread **Pulling the ALLER launch date forward?**
3. Compare claims with the source text, reading later replies as well as opening messages.

**Expected observation:** The shipped acceleration email thread ends with agreement to hold the existing launch date. Commercial enthusiasm is not, on its own, evidence that acceleration was approved. If the response suggests otherwise, compare it with the later replies and record the discrepancy. Meeting evidence may be retrieved from the provisioned Word transcript documents rather than a live meeting recording.

## Congratulations!

You have explored organizational knowledge directly in Copilot Chat. You can attempt any other lab independently after completing its own prerequisites.
