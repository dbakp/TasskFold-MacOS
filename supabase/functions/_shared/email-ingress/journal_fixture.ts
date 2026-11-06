// Synthetic pipeline fixture, not a deployment or provider implementation.
import { createEmailIngressHandler } from "./handler.ts";
import { fixtureConfig, fixtureEnvelope, signedFixture } from "./fixtures.ts";
const now = Date.now();
const { body, headers } = await signedFixture(fixtureEnvelope(now), now);
let argumentsForJournal: unknown;
const handler = createEmailIngressHandler(fixtureConfig, {
  now: () => now,
  // No durable admission is claimed. Production composition MUST provide it.
  admit: () => Promise.resolve({ allowed: true }),
  deliver: (args) => {
    argumentsForJournal = args;
    return Promise.resolve({ accepted: true, replayed: false });
  },
});
const reply = await handler(
  new Request("https://fixture.invalid/mail", {
    method: "POST",
    headers,
    body,
  }),
);
if (reply.status !== 200 || !argumentsForJournal) {
  throw Error("Synthetic preparation failed");
}
console.log(JSON.stringify(argumentsForJournal));
